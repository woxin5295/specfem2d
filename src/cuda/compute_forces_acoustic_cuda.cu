/*
!========================================================================
!
!                   S P E C F E M 2 D  Version 7 . 0
!                   --------------------------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                              CNRS, France
!                       and Princeton University, USA
!                 (there are currently many more authors!)
!                           (c) October 2017
!
! This software is a computer program whose purpose is to solve
! the two-dimensional viscoelastic anisotropic or poroelastic wave equation
! using a spectral-element method (SEM).
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
! The full text of the license is available in file "LICENSE".
!
!========================================================================
*/

#include "mesh_constants_cuda.h"


#ifdef USE_TEXTURES_FIELDS
realw_texture d_potential_tex;
realw_texture d_potential_dot_dot_tex;
//backward/reconstructed
realw_texture d_b_potential_tex;
realw_texture d_b_potential_dot_dot_tex;

//note: texture variables are implicitly static, and cannot be passed as arguments to cuda kernels;
//      thus, 1) we thus use if-statements (FORWARD_OR_ADJOINT) to determine from which texture to fetch from
//            2) we use templates
//      since if-statements are a bit slower as the variable is only known at runtime, we use option 2)

// templates definitions
template<int FORWARD_OR_ADJOINT> __device__ float texfetch_potential(int x);
template<int FORWARD_OR_ADJOINT> __device__ float texfetch_potential_dot_dot(int x);

// templates for texture fetching
// FORWARD_OR_ADJOINT == 1 <- forward arrays
template<> __device__ float texfetch_potential<1>(int x) { return tex1Dfetch(d_potential_tex, x); }
template<> __device__ float texfetch_potential_dot_dot<1>(int x) { return tex1Dfetch(d_potential_dot_dot_tex, x); }
// FORWARD_OR_ADJOINT == 3 <- backward/reconstructed arrays
template<> __device__ float texfetch_potential<3>(int x) { return tex1Dfetch(d_b_potential_tex, x); }
template<> __device__ float texfetch_potential_dot_dot<3>(int x) { return tex1Dfetch(d_b_potential_dot_dot_tex, x); }

#endif

#ifdef USE_TEXTURES_CONSTANTS
// already defined in compute_forces_viscoelastic_cuda.cu
extern realw_texture d_hprime_xx_tex;
//extern realw_texture d_hprimewgll_xx_tex;
extern realw_texture d_wxgll_xx_tex;
#endif


// note on performance optimizations:
//
//   performance tests done:
//   - registers: we were trying to reduce the number of registers, as this is the main limiter for the
//                occupancy of the kernel. however, there is only little difference in register pressure for one "general" kernel
//                or multiple "spezialized" kernels. reducing registers is mainly achieved through the launch_bonds() directive.
//   - branching: we were trying to reduce code branches, such as the if-active check in earlier code versions.
//                reducing the branching helps the compiler to better optimize the executable.
//   - memory accesses: the global memory accesses are avoiding texture reads for coalescent arrays, as this is
//                still faster. thus we were using no __ldg() loads or __restricted__ pointer usage,
//                as those implicitly lead the compiler to use texture reads.
//   - arithmetic intensity: ratio of floating-point operations vs. memory accesses is still low for our kernels.
//                tests with using a loop over elements to re-use the constant arrays (like hprime, wgllwgll,..) and thus
//                increasing the arithmetic intensity failed because the number of registers increased as well.
//                this increased register pressure reduced the occupancy and slowed down the kernel performance.
//   - hiding memory latency: to minimize waiting times to retrieve a memory value from global memory, we put
//                some more calculations into the same code block before calling syncthreads(). this should help the
//                compiler to move independent calculations to wherever it can overlap it with memory access operations.
//                note, especially the if (gravity )-block locations are very sensitive
//                for optimal register usage and compiler optimizations
//

/* ----------------------------------------------------------------------------------------------- */

// KERNEL 2 - acoustic compute forces kernel

/* ----------------------------------------------------------------------------------------------- */

template<int FORWARD_OR_ADJOINT> __global__ void
#ifdef USE_LAUNCH_BOUNDS
// adds compiler specification
__launch_bounds__(NGLL2_PADDED,LAUNCH_MIN_BLOCKS_ACOUSTIC)
#endif
Kernel_2_acoustic_impl(const int nb_blocks_to_compute,
                       const int* d_ibool,
                       const int* d_phase_ispec_inner_acoustic,
                       const int num_phase_ispec_acoustic,
                       const int d_iphase,
                       realw_const_p d_potential_acoustic,
                       realw_p d_potential_dot_dot_acoustic,
                       realw_const_p d_b_potential_acoustic,
                       realw_p d_b_potential_dot_dot_acoustic,
                       const int nb_field,
                       const realw* d_xix, const realw* d_xiz,
                       const realw* d_gammax,const realw* d_gammaz,
                       realw_const_p d_hprime_xx,
                       realw_const_p d_hprimewgll_xx,
                       realw_const_p d_wxgll,
                       const realw* d_rhostore,
                       int PML,
                       int* spec_to_PML){

  // block-id == number of local element id in phase_ispec array
  int bx = blockIdx.y*gridDim.x+blockIdx.x;

  // thread-id == GLL node id
  // note: use only NGLL^2 = 25 active threads, plus 7 inactive/ghost threads,
  //       because we used memory padding from NGLL^2 = 25 to 32 to get coalescent memory accesses;
  //       to avoid execution branching and the need of registers to store an active state variable,
  //       the thread ids are put in valid range
  int tx = threadIdx.x;

  int I,J;
  int iglob,offset;

  realw temp1l,temp3l;
  realw xixl,xizl,gammaxl,gammazl;

  realw dpotentialdxl,dpotentialdzl;
  realw rho_invl_times_jacobianl;

  realw sum_terms;

  __shared__ realw s_dummy_loc[2*NGLL2];

  __shared__ realw s_temp1[NGLL2];
  __shared__ realw s_temp3[NGLL2];

  __shared__ realw sh_hprime_xx[NGLL2];
  __shared__ realw sh_hprimewgll_xx[NGLL2];
  __shared__ realw sh_wxgll[NGLLX];



// arithmetic intensity: ratio of number-of-arithmetic-operations / number-of-bytes-accessed-on-DRAM
//
// hand-counts on floating-point operations: counts addition/subtraction/multiplication/division
//                                           no counts for operations on indices in for-loops (compiler will likely unrool loops)
//
//                                           counts accesses to global memory, but no shared memory or register loads/stores
//                                           float has 4 bytes

//         counts floating-point operations (FLOP) per thread
//         counts global memory accesses in bytes (BYTES) per block
// 2 FLOP
//
// 0 BYTES

  // checks if anything to do
  if (bx >= nb_blocks_to_compute ) return;

// counts:
// + 1 FLOP
//
// + 0 BYTE

  // local padded index
  offset = (d_phase_ispec_inner_acoustic[bx + num_phase_ispec_acoustic*(d_iphase-1)]-1)*NGLL2_PADDED + tx;

  //checks if element is outside the PML
  if(PML) if (spec_to_PML[(offset -tx)/NGLL2_PADDED] > 0) return;


  // global index
  iglob = d_ibool[offset] - 1;


// counts:
// + 7 FLOP
//
// + 2 float * 32 threads = 256 BYTE

#ifdef USE_TEXTURES_FIELDS
  s_dummy_loc[tx] = texfetch_potential<FORWARD_OR_ADJOINT>(iglob);
  if (nb_field==2) s_dummy_loc[NGLL2+tx]=texfetch_potential<3>(iglob);
#else
  // changing iglob indexing to match fortran row changes fast style
  s_dummy_loc[tx] = d_potential_acoustic[iglob];
  if (nb_field==2) s_dummy_loc[NGLL2+tx]=d_b_potential_acoustic[iglob];
#endif


// counts:
// + 0 FLOP
//
// + 1 float * 25 threads = 100 BYTE

  // local index
  J = (tx/NGLLX);
  I = (tx-J*NGLLX);

// counts:
// + 3 FLOP
//
// + 0 BYTES

  // note: loads mesh values here to give compiler possibility to overlap memory fetches with some computations;
  //       arguments defined as realw* instead of const realw* __restrict__ to avoid that the compiler
  //       loads all memory by texture loads (arrays accesses are coalescent, thus no need for texture reads)
  //
  // calculates laplacian
  xixl = get_global_cr( &d_xix[offset] );
  xizl = d_xiz[offset];
  gammaxl = d_gammax[offset];
  gammazl = d_gammaz[offset];

  rho_invl_times_jacobianl = 1.f /(d_rhostore[offset] * (xixl*gammazl-gammaxl*xizl));

// counts:
// + 5 FLOP
//
// + 5 float * 32 threads = 160 BYTE

  // loads hprime into shared memory

#ifdef USE_TEXTURES_CONSTANTS
  sh_hprime_xx[tx] = tex1Dfetch(d_hprime_xx_tex,tx);
#else
  sh_hprime_xx[tx] = d_hprime_xx[tx];
#endif
  // loads hprimewgll into shared memory
  sh_hprimewgll_xx[tx] = d_hprimewgll_xx[tx];

  if (threadIdx.x < NGLLX){
#ifdef USE_TEXTURES_CONSTANTS
    sh_wxgll[tx] = tex1Dfetch(d_wxgll_xx_tex,tx);
#else
    // changing iglob indexing to match fortran row changes fast style
    sh_wxgll[tx] = d_wxgll[tx];
#endif
  }


// counts:
// + 0 FLOP
//
// + 2 * 1 float * 25 threads = 200 BYTE

  for (int k=0 ; k < nb_field ; k++) {

    // synchronize all the threads (one thread for each of the NGLL grid points of the
    // current spectral element) because we need the whole element to be ready in order
    // to be able to compute the matrix products along cut planes of the 3D element below
    __syncthreads();

    // computes first matrix product
    temp1l = 0.f;
    temp3l = 0.f;

    for (int l=0;l<NGLLX;l++) {

      //assumes that hprime_xx = hprime_yy = hprime_zz
      // 1. cut-plane along xi-direction
      temp1l += s_dummy_loc[NGLL2*k+J*NGLLX+l] * sh_hprime_xx[l*NGLLX+I];
      // 3. cut-plane along gamma-direction
      temp3l += s_dummy_loc[NGLL2*k+l*NGLLX+I] * sh_hprime_xx[l*NGLLX+J];
    }

// counts:
// + NGLLX * 2 * 6 FLOP = 60 FLOP
//
// + 0 BYTE

    // compute derivatives of ux, uy and uz with respect to x, y and z
    // derivatives of potential
    dpotentialdxl = xixl*temp1l +  gammaxl*temp3l;
    dpotentialdzl = xizl*temp1l +  gammazl*temp3l;

// counts:
// + 2 * 3 FLOP = 6 FLOP
//
// + 0 BYTE

    // form the dot product with the test vector
    s_temp1[tx] = sh_wxgll[J]*rho_invl_times_jacobianl  * (dpotentialdxl*xixl  + dpotentialdzl*xizl)  ;
    s_temp3[tx] = sh_wxgll[I]*rho_invl_times_jacobianl  * (dpotentialdxl*gammaxl + dpotentialdzl*gammazl)  ;

// counts:
// + 2 * 6 FLOP = 12 FLOP
//
// + 2 BYTE

    // synchronize all the threads (one thread for each of the NGLL grid points of the
    // current spectral element) because we need the whole element to be ready in order
    // to be able to compute the matrix products along cut planes of the 3D element below
    __syncthreads();

    sum_terms = 0.f;
    for (int l=0;l<NGLLX;l++) {
      //assumes hprimewgll_xx = hprimewgll_zz
      sum_terms -= s_temp1[J*NGLLX+l] * sh_hprimewgll_xx[I*NGLLX+l] + s_temp3[l*NGLLX+I] * sh_hprimewgll_xx[J*NGLLX+l];
    }

// counts:
// + NGLLX * 11 FLOP = 55 FLOP
//
// + 0 BYTE

    // assembles potential array
    if (k==0) {
      atomicAdd(&d_potential_dot_dot_acoustic[iglob],sum_terms);
    } else {
      atomicAdd(&d_b_potential_dot_dot_acoustic[iglob],sum_terms);
    }
// counts:
// + 1 FLOP
//
// + 1 float * 25 threads = 100 BYTE

// -----------------
// total of: 149 FLOP per thread
//           ~ 32 * 149 = 4768 FLOP per block
//
//           818 BYTE DRAM accesses per block
//
//           -> arithmetic intensity: 4768 FLOP / 818 BYTES ~ 5.83 FLOP/BYTE (hand-count)
  } // nb_field loop
}



/* ----------------------------------------------------------------------------------------------- */

// KERNEL 2 - acoustic compute forces kernel with PML

/* ----------------------------------------------------------------------------------------------- */

template<int FORWARD_OR_ADJOINT> __global__ void
#ifdef USE_LAUNCH_BOUNDS
// adds compiler specification
__launch_bounds__(NGLL2,LAUNCH_MIN_BLOCKS_ACOUSTIC)
#endif
Kernel_2_acoustic_PML_impl(const int nb_blocks_to_compute,
                           const int* d_ibool,
                           const int* d_phase_ispec_inner_acoustic,
                           const int num_phase_ispec_acoustic,
                           const int d_iphase,
                           realw_const_p d_potential_acoustic,
                           realw_p d_potential_dot_dot_acoustic,
                           const realw* d_xix, const realw* d_xiz,
                           const realw* d_gammax,const realw* d_gammaz,
                           realw_const_p d_hprime_xx,
                           realw_const_p d_hprimewgll_xx,
                           realw_const_p d_wxgll,
                           const realw* d_rhostore,
                           int* spec_to_PML,
                           realw ALPHA_MAX_PML,
                           realw d0,
                           realw* abs_normalized,
                           int NSPEC_PML_X,
                           int NSPEC_PML_Z,
                           realw deltat,
                           realw* PML_dpotentialdxl_old,
                           realw* PML_dpotentialdzl_old,
                           realw* dpotential_old,
                           realw* rmemory_acoustic_dux_dx,
                           realw* rmemory_acoustic_dux_dz,
                           realw* rmemory_acoustic_dux_dx2,
                           realw* rmemory_acoustic_dux_dz2,
                           realw* rmemory_pot_acoustic,
                           realw* rmemory_pot_acoustic2,
                           realw_p potential_dot,
                           realw* d_kappastore,
                           realw* alphax_store,
                           realw* alphaz_store,
                           realw* betax_store,
                           realw* betaz_store){

  // block-id == number of local element id in phase_ispec array
  int bx = blockIdx.y*gridDim.x+blockIdx.x;

  int tx = threadIdx.x;

  int I,J;
  int iglob,offset;

  realw temp1l,temp3l;
  realw xixl,xizl,gammaxl,gammazl;

  realw dpotentialdxl,dpotentialdzl;
  realw rho_invl_times_jacobianl;

  realw sum_terms;

  __shared__ realw s_dummy_loc[NGLL2];

  __shared__ realw s_temp1[NGLL2];
  __shared__ realw s_temp3[NGLL2];

  __shared__ realw sh_hprime_xx[NGLL2];
  __shared__ realw sh_hprimewgll_xx[NGLL2];
  __shared__ realw sh_wxgll[NGLLX];

  int ispec, ispec_pml;
  realw alpha1,beta1,alphax,betax,abs_norm;
  realw coef1,coef2,coef3,coef4,pml_contrib;
  realw r1,r2,r3,r4,r5,r6;

  // checks if anything to do
  if (bx >= nb_blocks_to_compute ) return;

  ispec = d_phase_ispec_inner_acoustic[bx + num_phase_ispec_acoustic*(d_iphase-1)]-1;
  ispec_pml = spec_to_PML[ispec];

  //checks if element is inside the PML
  if (ispec_pml==0) return;

  // local padded index
  offset = ispec*NGLL2_PADDED + tx;

  // global index
  iglob = d_ibool[offset] - 1;

#ifdef USE_TEXTURES_FIELDS
  s_dummy_loc[tx] = texfetch_potential<FORWARD_OR_ADJOINT>(iglob);
#else
  // changing iglob indexing to match fortran row changes fast style
  s_dummy_loc[tx] = d_potential_acoustic[iglob];
#endif

  // local index
  J = (tx/NGLLX);
  I = (tx-J*NGLLX);

  // calculates jacobian
  xixl = get_global_cr( &d_xix[offset] );
  xizl = d_xiz[offset];
  gammaxl = d_gammax[offset];
  gammazl = d_gammaz[offset];

  rho_invl_times_jacobianl = 1.f /(d_rhostore[offset] * (xixl*gammazl-gammaxl*xizl));

  // loads hprime into shared memory

#ifdef USE_TEXTURES_CONSTANTS
  sh_hprime_xx[tx] = tex1Dfetch(d_hprime_xx_tex,tx);
#else
  sh_hprime_xx[tx] = d_hprime_xx[tx];
#endif
  // loads hprimewgll into shared memory
  sh_hprimewgll_xx[tx] = d_hprimewgll_xx[tx];

  if (threadIdx.x < NGLLX){
#ifdef USE_TEXTURES_CONSTANTS
    sh_wxgll[tx] = tex1Dfetch(d_wxgll_xx_tex,tx);
#else
    // changing iglob indexing to match fortran row changes fast style
    sh_wxgll[tx] = d_wxgll[tx];
#endif
  }

  __syncthreads();

  // computes first matrix product
  temp1l = 0.f;
  temp3l = 0.f;

  for (int l=0;l<NGLLX;l++) {

    //assumes that hprime_xx = hprime_yy = hprime_zz
    // 1. cut-plane along xi-direction
    temp1l += s_dummy_loc[J*NGLLX+l] * sh_hprime_xx[l*NGLLX+I];
    // 3. cut-plane along gamma-direction
    temp3l += s_dummy_loc[l*NGLLX+I] * sh_hprime_xx[l*NGLLX+J];
  }

  // compute derivatives of ux, uy and uz with respect to x and z
  // derivatives of potential
  dpotentialdxl = xixl*temp1l +  gammaxl*temp3l;
  dpotentialdzl = xizl*temp1l +  gammazl*temp3l;

  if (ispec_pml - 1 < NSPEC_PML_X + NSPEC_PML_Z){
    abs_norm = abs_normalized[(ispec_pml-1)*NGLL2 + tx ];
    alpha1 = ALPHA_MAX_PML * ( 1.f - abs_norm ) ;
    beta1 =  alpha1 + 2.f * d0  * abs_norm * abs_norm;}
  else{
    alpha1 = alphaz_store[(ispec_pml-1-(NSPEC_PML_X + NSPEC_PML_Z))*NGLL2 + tx ];
    beta1  = betaz_store[(ispec_pml-1-(NSPEC_PML_X + NSPEC_PML_Z))*NGLL2 + tx ];
    alphax = alphax_store[(ispec_pml-1-(NSPEC_PML_X + NSPEC_PML_Z))*NGLL2 + tx ];
    betax  = betax_store[(ispec_pml-1-(NSPEC_PML_X + NSPEC_PML_Z))*NGLL2 + tx ];
  }
  coef1 = __expf(-0.5f * deltat * alpha1);
  coef2 = __expf(-0.5f * deltat * beta1);
  // Update memory variables of derivatives
  r1 = rmemory_acoustic_dux_dx[(ispec_pml-1)*NGLL2 + tx ];
  r2 = rmemory_acoustic_dux_dz[(ispec_pml-1)*NGLL2 + tx ];
  if (ispec_pml - 1 < NSPEC_PML_X){
    r1 *= coef2 * coef2;
    if (abs(beta1) > 0.00001){
      r1 += ( 1.f - coef2 ) / beta1 * dpotentialdxl + coef2 * ( 1.f - coef2 ) / beta1 * PML_dpotentialdxl_old[(ispec_pml-1)*NGLL2 + tx];}
    else{
      r1 += 0.5f * deltat * dpotentialdxl + 0.5f* deltat * PML_dpotentialdxl_old[(ispec_pml-1)*NGLL2 + tx];
    }
    r2 *= coef1 * coef1;
    if (abs(alpha1) > 0.00001){
      r2 += ( 1.f - coef1 ) / alpha1 * dpotentialdzl + coef1 * ( 1.f - coef1 ) / alpha1 * PML_dpotentialdzl_old[(ispec_pml-1)*NGLL2 + tx];}
    else{
      r2 += 0.5f * deltat * dpotentialdzl + 0.5f* deltat * PML_dpotentialdzl_old[(ispec_pml-1)*NGLL2 + tx];
    }
  }else{
    r1 *= coef1 * coef1;
    if (abs(alpha1) > 0.00001){
      r1 += ( 1.f - coef1 ) / alpha1 * dpotentialdxl + coef1 * ( 1.f - coef1 ) / alpha1 * PML_dpotentialdxl_old[(ispec_pml-1)*NGLL2 + tx];}
    else{
      r1 += 0.5f * deltat * dpotentialdxl + 0.5f* deltat * PML_dpotentialdxl_old[(ispec_pml-1)*NGLL2 + tx];
    }
    r2 *= coef2 * coef2;
     if (abs(beta1) > 0.00001){
       r2 += ( 1.f - coef2 ) / beta1 * dpotentialdzl + coef2 * ( 1.f - coef2 ) / beta1 * PML_dpotentialdzl_old[(ispec_pml-1)*NGLL2 + tx];}
     else{
       r2 += 0.5f * deltat * dpotentialdzl + 0.5f * deltat * PML_dpotentialdzl_old[(ispec_pml-1)*NGLL2 + tx];
     }
  }
  rmemory_acoustic_dux_dx[(ispec_pml-1)*NGLL2 + tx ] = r1;
  rmemory_acoustic_dux_dz[(ispec_pml-1)*NGLL2 + tx ] = r2;

  if (ispec_pml - 1 >= NSPEC_PML_X + NSPEC_PML_Z){
    coef3 = __expf(-0.5f * deltat * betax);
    coef4 = __expf(-0.5f * deltat * alphax);

    r3 = coef3 * coef3 * rmemory_acoustic_dux_dx2[(ispec_pml-1- NSPEC_PML_X - NSPEC_PML_Z)*NGLL2 + tx ];
    if (abs(betax) > 0.00001){
      r3 += ( 1.f - coef3 ) / betax * dpotentialdxl + coef3 * ( 1.f - coef3 ) / betax * PML_dpotentialdxl_old[(ispec_pml-1)*NGLL2 + tx];
    }else{
      r3 += 0.5f * deltat * dpotentialdxl + 0.5f * deltat * PML_dpotentialdxl_old[(ispec_pml-1)*NGLL2 + tx];
    }
    r4 = coef4 * coef4 * rmemory_acoustic_dux_dz2[(ispec_pml-1- NSPEC_PML_X - NSPEC_PML_Z)*NGLL2 + tx ];
    if (abs(alphax) > 0.00001){
      r4 += ( 1.f - coef4 ) / alphax * dpotentialdzl + coef4 * ( 1.f - coef4 ) / alphax * PML_dpotentialdzl_old[(ispec_pml-1)*NGLL2 + tx];
    }else{
      r4 += 0.5f * deltat * dpotentialdzl + 0.5f * deltat * PML_dpotentialdzl_old[(ispec_pml-1)*NGLL2 + tx];
    }
    rmemory_acoustic_dux_dx2[(ispec_pml-1- NSPEC_PML_X - NSPEC_PML_Z)*NGLL2 + tx ] = r3;
    rmemory_acoustic_dux_dz2[(ispec_pml-1- NSPEC_PML_X - NSPEC_PML_Z)*NGLL2 + tx ] = r4;

  } // ispec \in REGION_XZ

  // Update memory variables of potential
  r5 = coef1 * coef1 * rmemory_pot_acoustic[(ispec_pml-1)*NGLL2 + tx ];
  if (abs(alpha1) > 0.00001){
    r5 += ( 1.f - coef1 ) / alpha1 *  s_dummy_loc[tx] + coef1 * ( 1.f - coef1 ) / alpha1 * dpotential_old[(ispec_pml-1)*NGLL2 + tx];}
  else{
    r5 += 0.5f * deltat *  s_dummy_loc[tx] + 0.5f * deltat * dpotential_old[(ispec_pml-1)*NGLL2 + tx];
  }
  rmemory_pot_acoustic[(ispec_pml-1)*NGLL2 + tx ] = r5 ;
  if (ispec_pml - 1 >= NSPEC_PML_X + NSPEC_PML_Z){
    r6 = coef4 * coef4 * rmemory_pot_acoustic2[(ispec_pml-1- NSPEC_PML_X - NSPEC_PML_Z)*NGLL2 + tx ];
    if (abs(alphax) > 0.00001){
      r6 += ( 1.f - coef4 ) / alphax *  s_dummy_loc[tx] + coef4 * ( 1.f - coef4 ) / alphax * dpotential_old[(ispec_pml-1)*NGLL2 + tx];
    }else{
      r6 += 0.5f * deltat * s_dummy_loc[tx] + 0.5f * deltat * dpotential_old[(ispec_pml-1)*NGLL2 + tx];
    }
    rmemory_pot_acoustic2[(ispec_pml-1- NSPEC_PML_X - NSPEC_PML_Z)*NGLL2 + tx ] = r6;
  } // ispec \in REGION_XZ

  // Update old potential
  PML_dpotentialdxl_old[(ispec_pml-1)*NGLL2 + tx] = dpotentialdxl;
  PML_dpotentialdzl_old[(ispec_pml-1)*NGLL2 + tx] = dpotentialdzl;
  dpotential_old[(ispec_pml-1)*NGLL2 + tx] = s_dummy_loc[tx];

  // Compute contribution of the PML to second derivative of potential
  coef2 = rho_invl_times_jacobianl* d_rhostore[offset] / d_kappastore[ispec*NGLL2 + tx];

  if (ispec_pml - 1 < NSPEC_PML_X + NSPEC_PML_Z){
    pml_contrib = sh_wxgll[J] * sh_wxgll[I] * coef2 * ( (beta1-alpha1) * potential_dot[iglob] - alpha1 * (beta1-alpha1) * s_dummy_loc[tx] + alpha1 * alpha1 * (beta1-alpha1) * r5 );
  }else{
    coef3 = (alphax * alpha1 + alphax*alphax + 2.f * betax * beta1 - 2.f * alphax * (betax + beta1)) / (alpha1 - alphax);
    coef4 = (alphax * alpha1 + alpha1*alpha1 + 2.f * betax * beta1 - 2.f * alpha1 * (betax + beta1)) / (alphax - alpha1);
    pml_contrib = sh_wxgll[J] * sh_wxgll[I] * coef2 * ( 0.5f * (coef3 - alphax + coef4 - alpha1) * potential_dot[iglob] + 0.5f * (alphax*alphax - coef3 * alphax + alpha1*alpha1 - coef4 * alpha1)*s_dummy_loc[tx] + 0.5f * alphax * alphax * (coef3 - alphax) * r6  + 0.5f * alpha1 * alpha1 * (coef4 - alpha1) * r5);
  }

  // Update derivatives
  if (ispec_pml - 1 < NSPEC_PML_X){
    dpotentialdxl += (alpha1-beta1) * r1;
    dpotentialdzl -= (alpha1-beta1) * r2;}
  else if (ispec_pml - 1 < NSPEC_PML_X + NSPEC_PML_Z){
    dpotentialdxl -= (alpha1-beta1) * r1;
    dpotentialdzl += (alpha1-beta1) * r2;}
  else{
    dpotentialdxl += 0.5f * ((alpha1 * betax + alpha1*alpha1 + 2.f * beta1 * alphax - 2.f * alpha1 * ( beta1 + alphax)) / (betax - alpha1) - alpha1 ) * r1;
    dpotentialdxl += 0.5f * ((alpha1 * betax + betax*betax + 2.f * beta1 * alphax - 2.f * betax * ( beta1 + alphax)) / (alpha1 - betax) - betax ) * r3;
    dpotentialdzl += 0.5f * ((alphax * beta1 + alphax*alphax + 2.f * betax * alpha1 - 2.f * alphax * ( betax + alpha1)) / (beta1 - alphax) - alphax ) * r4;
    dpotentialdzl += 0.5f * ((alphax * beta1 + beta1*beta1 + 2.f * betax * alpha1 - 2.f * beta1 * ( betax + alpha1)) / (alphax - beta1) - beta1 ) * r2;
  }

  __syncthreads();

  // form the dot product with the test vector
  s_temp1[tx] = sh_wxgll[J]*rho_invl_times_jacobianl  * (dpotentialdxl*xixl  + dpotentialdzl*xizl)  ;
  s_temp3[tx] = sh_wxgll[I]*rho_invl_times_jacobianl  * (dpotentialdxl*gammaxl + dpotentialdzl*gammazl)  ;

  __syncthreads();

  sum_terms = 0.f;
  for (int l=0;l<NGLLX;l++) {
    //assumes hprimewgll_xx = hprimewgll_zz
    sum_terms -= s_temp1[J*NGLLX+l] * sh_hprimewgll_xx[I*NGLLX+l] + s_temp3[l*NGLLX+I] * sh_hprimewgll_xx[J*NGLLX+l];
  }

  // assembles potential array
  atomicAdd(&d_potential_dot_dot_acoustic[iglob],sum_terms-pml_contrib);
}

/* ----------------------------------------------------------------------------------------------- */

// KERNEL 2 - viscoacoustic compute forces kernel

/* ----------------------------------------------------------------------------------------------- */

template<int FORWARD_OR_ADJOINT> __global__ void
#ifdef USE_LAUNCH_BOUNDS
// adds compiler specification
__launch_bounds__(NGLL2_PADDED,LAUNCH_MIN_BLOCKS_ACOUSTIC)
#endif
Kernel_2_viscoacoustic_impl(const int nb_blocks_to_compute,
                            const int* d_ibool,
                            const int* d_phase_ispec_inner_acoustic,
                            const int num_phase_ispec_acoustic,
                            const int d_iphase,
                            realw_const_p d_potential_acoustic,
                            realw_p d_potential_dot_dot_acoustic,
                            const realw* d_xix, const realw* d_xiz,
                            const realw* d_gammax,const realw* d_gammaz,
                            realw_const_p d_hprime_xx,
                            realw_const_p d_hprimewgll_xx,
                            realw_const_p d_wxgll,
                            const realw* d_rhostore,
                            realw_p d_e1_acous,
                            const realw* d_A_newmark,
                            const realw* d_B_newmark,
                            realw_p d_sum_forces_old){

  // block-id == number of local element id in phase_ispec array
  int bx = blockIdx.y*gridDim.x+blockIdx.x;
  int tx = threadIdx.x;
  int I,J;
  int iglob,offset,offset_align,i_sls;

  realw temp1l,temp3l;
  realw xixl,xizl,gammaxl,gammazl;
  realw dpotentialdxl,dpotentialdzl;
  realw rho_invl_times_jacobianl;
  realw sum_terms;
  realw sum_forces_old,forces_attenuation,a_newmark;
  realw e1_acous_load[N_SLS];

  __shared__ realw s_dummy_loc[NGLL2];
  __shared__ realw s_temp1[NGLL2];
  __shared__ realw s_temp3[NGLL2];
  __shared__ realw sh_hprime_xx[NGLL2];
  __shared__ realw sh_hprimewgll_xx[NGLL2];
  __shared__ realw sh_wxgll[NGLLX];

  if (bx >= nb_blocks_to_compute ) return;

  I =d_phase_ispec_inner_acoustic[bx + num_phase_ispec_acoustic*(d_iphase-1)]-1;
  offset = I*NGLL2_PADDED + tx;
  offset_align = I*NGLL2 + tx;
  iglob = d_ibool[offset] - 1;

#ifdef USE_TEXTURES_FIELDS
  s_dummy_loc[tx] = texfetch_potential<FORWARD_OR_ADJOINT>(iglob);
#else
  s_dummy_loc[tx] = d_potential_acoustic[iglob];
#endif

  // local index
  J = (tx/NGLLX);
  I = (tx-J*NGLLX);

  xixl = get_global_cr( &d_xix[offset] );
  xizl = d_xiz[offset];
  gammaxl = d_gammax[offset];
  gammazl = d_gammaz[offset];

  rho_invl_times_jacobianl = 1.f /(d_rhostore[offset] * (xixl*gammazl-gammaxl*xizl));

  for (i_sls=0;i_sls<N_SLS;i_sls++)  e1_acous_load[i_sls] = d_e1_acous[N_SLS*offset_align+i_sls];

#ifdef USE_TEXTURES_CONSTANTS
  sh_hprime_xx[tx] = tex1Dfetch(d_hprime_xx_tex,tx);
#else
  sh_hprime_xx[tx] = d_hprime_xx[tx];
#endif
  // loads hprimewgll into shared memory
  sh_hprimewgll_xx[tx] = d_hprimewgll_xx[tx];

  if (threadIdx.x < NGLLX){
#ifdef USE_TEXTURES_CONSTANTS
    sh_wxgll[tx] = tex1Dfetch(d_wxgll_xx_tex,tx);
#else
    sh_wxgll[tx] = d_wxgll[tx];
#endif
  }

  __syncthreads();

  // computes first matrix product
  temp1l = 0.f;
  temp3l = 0.f;

  for (int l=0;l<NGLLX;l++) {
    //assumes that hprime_xx = hprime_yy = hprime_zz
    // 1. cut-plane along xi-direction
    temp1l += s_dummy_loc[J*NGLLX+l] * sh_hprime_xx[l*NGLLX+I];
    // 3. cut-plane along gamma-direction
    temp3l += s_dummy_loc[l*NGLLX+I] * sh_hprime_xx[l*NGLLX+J];
  }

  dpotentialdxl = xixl*temp1l +  gammaxl*temp3l;
  dpotentialdzl = xizl*temp1l +  gammazl*temp3l;
  s_temp1[tx] = sh_wxgll[J]*rho_invl_times_jacobianl  * (dpotentialdxl*xixl  + dpotentialdzl*xizl)  ;
  s_temp3[tx] = sh_wxgll[I]*rho_invl_times_jacobianl  * (dpotentialdxl*gammaxl + dpotentialdzl*gammazl)  ;

  __syncthreads();

  sum_terms = 0.f;
  for (int l=0;l<NGLLX;l++) {
    //assumes hprimewgll_xx = hprimewgll_zz
    sum_terms -= s_temp1[J*NGLLX+l] * sh_hprimewgll_xx[I*NGLLX+l] + s_temp3[l*NGLLX+I] * sh_hprimewgll_xx[J*NGLLX+l];
  }

  sum_forces_old = d_sum_forces_old[offset_align];
  forces_attenuation = 0.f;

  for (i_sls=0;i_sls<N_SLS;i_sls++){
    a_newmark = d_A_newmark[N_SLS * offset_align + i_sls];
    e1_acous_load[i_sls] = a_newmark * a_newmark * e1_acous_load[i_sls] + d_B_newmark[N_SLS * offset_align + i_sls] * (sum_terms + a_newmark * sum_forces_old);
    forces_attenuation += e1_acous_load[i_sls];
    d_e1_acous[N_SLS*offset_align+i_sls] = e1_acous_load[i_sls];
  }

  d_sum_forces_old[offset_align] = sum_terms;
  sum_terms += forces_attenuation;

  atomicAdd(&d_potential_dot_dot_acoustic[iglob],sum_terms);
}




/* ----------------------------------------------------------------------------------------------- */

void Kernel_2_acoustic(int nb_blocks_to_compute, Mesh* mp, int d_iphase,
                       int* d_ibool,
                       realw* d_xix,realw* d_xiz,
                       realw* d_gammax,realw* d_gammaz,
                       realw* d_rhostore,
                       int ATTENUATION_VISCOACOUSTIC,
                       int compute_wavefield_1,
                       int compute_wavefield_2) {

#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING
  exit_on_cuda_error("before acoustic kernel Kernel 2");
#endif

  // if the grid can handle the number of blocks, we let it be 1D
  int blocksize = NGLL2;

  int num_blocks_x, num_blocks_y, nb_field;
  get_blocks_xy(nb_blocks_to_compute,&num_blocks_x,&num_blocks_y);

  dim3 grid(num_blocks_x,num_blocks_y);
  dim3 threads(blocksize,1,1);

  // Cuda timing
  cudaEvent_t start, stop;
  if (CUDA_TIMING) {
    start_timing_cuda(&start,&stop);
  }

  if (compute_wavefield_1 && compute_wavefield_2){
    nb_field=2;
  }else{
    nb_field=1;
  }
  if ( ! ATTENUATION_VISCOACOUSTIC){
    if (nb_field==2){
      // forward wavefields -> FORWARD_OR_ADJOINT == 1
      Kernel_2_acoustic_impl<1><<<grid,threads,0,mp->compute_stream>>>(nb_blocks_to_compute,
                                                                       d_ibool,
                                                                       mp->d_phase_ispec_inner_acoustic,
                                                                       mp->num_phase_ispec_acoustic,
                                                                       d_iphase,
                                                                       mp->d_potential_acoustic, mp->d_potential_dot_dot_acoustic,
                                                                       mp->d_b_potential_acoustic,mp->d_b_potential_dot_dot_acoustic,
                                                                       nb_field,
                                                                       d_xix, d_xiz,
                                                                       d_gammax, d_gammaz,
                                                                       mp->d_hprime_xx,
                                                                       mp->d_hprimewgll_xx,
                                                                       mp->d_wxgll,
                                                                       d_rhostore,
                                                                       mp->pml,
                                                                       mp->spec_to_pml);
    }else{ // nb_field==1
      if (compute_wavefield_1){
        // forward wavefields -> FORWARD_OR_ADJOINT == 1
        Kernel_2_acoustic_impl<1><<<grid,threads,0,mp->compute_stream>>>(nb_blocks_to_compute,
                                                                         d_ibool,
                                                                         mp->d_phase_ispec_inner_acoustic,
                                                                         mp->num_phase_ispec_acoustic,
                                                                         d_iphase,
                                                                         mp->d_potential_acoustic, mp->d_potential_dot_dot_acoustic,
                                                                         mp->d_b_potential_acoustic,mp->d_b_potential_dot_dot_acoustic,
                                                                         nb_field,
                                                                         d_xix, d_xiz,
                                                                         d_gammax, d_gammaz,
                                                                         mp->d_hprime_xx,
                                                                         mp->d_hprimewgll_xx,
                                                                         mp->d_wxgll,
                                                                         d_rhostore,
                                                                         mp->pml,
                                                                         mp->spec_to_pml);

        if (mp->pml){
          Kernel_2_acoustic_PML_impl<1><<<grid,threads,0,mp->compute_stream>>>(nb_blocks_to_compute,
                                                                           d_ibool,
                                                                           mp->d_phase_ispec_inner_acoustic,
                                                                           mp->num_phase_ispec_acoustic,
                                                                           d_iphase,
                                                                           mp->d_potential_acoustic, mp->d_potential_dot_dot_acoustic,
                                                                           d_xix, d_xiz,
                                                                           d_gammax, d_gammaz,
                                                                           mp->d_hprime_xx,
                                                                           mp->d_hprimewgll_xx,
                                                                           mp->d_wxgll,
                                                                           d_rhostore,
                                                                           mp->spec_to_pml,
                                                                           mp->ALPHA_MAX_PML,
                                                                           mp->d0_max,
                                                                           mp->abscissa_norm,
                                                                           mp->nspec_pml_x,
                                                                           mp->nspec_pml_z,
                                                                           mp->deltat,
                                                                           mp->PML_dpotentialdxl_old,
                                                                           mp->PML_dpotentialdzl_old,
                                                                           mp->dpotential_old,
                                                                           mp->rmemory_acoustic_dux_dx,
                                                                           mp->rmemory_acoustic_dux_dz,
                                                                           mp->rmemory_acoustic_dux_dx2,
                                                                           mp->rmemory_acoustic_dux_dz2,
                                                                           mp->rmemory_pot_acoustic,
                                                                           mp->rmemory_pot_acoustic2,
                                                                           mp->d_potential_dot_acoustic,
                                                                           mp->d_kappastore,
                                                                           mp->alphax_store,
                                                                           mp->alphaz_store,
                                                                           mp->betax_store,
                                                                           mp->betaz_store);
        } //PML
      } // compute_wavefield1
      if (compute_wavefield_2){
        // this run only happens with UNDO_ATTENUATION_AND_OR_PML on
        // adjoint wavefields -> FORWARD_OR_ADJOINT == 3
        Kernel_2_acoustic_impl<3><<<grid,threads,0,mp->compute_stream>>>(nb_blocks_to_compute,
                                                                         d_ibool,
                                                                         mp->d_phase_ispec_inner_acoustic,
                                                                         mp->num_phase_ispec_acoustic,
                                                                         d_iphase,
                                                                         mp->d_b_potential_acoustic, mp->d_b_potential_dot_dot_acoustic,
                                                                         mp->d_b_potential_acoustic,mp->d_b_potential_dot_dot_acoustic,
                                                                         nb_field,
                                                                         d_xix, d_xiz,
                                                                         d_gammax, d_gammaz,
                                                                         mp->d_hprime_xx,
                                                                         mp->d_hprimewgll_xx,
                                                                         mp->d_wxgll,
                                                                         d_rhostore,
                                                                         mp->pml,
                                                                         mp->spec_to_pml);
      } //compute_wavefield_1
    } //nb_field
  }else{ // ATTENUATION_VISCOACOUSTIC== .true. below
    if (compute_wavefield_1) {
      Kernel_2_viscoacoustic_impl<1><<<grid,threads,0,mp->compute_stream>>>(nb_blocks_to_compute,
                                                                            d_ibool,
                                                                            mp->d_phase_ispec_inner_acoustic,
                                                                            mp->num_phase_ispec_acoustic,
                                                                            d_iphase,
                                                                            mp->d_potential_acoustic, mp->d_potential_dot_dot_acoustic,
                                                                            d_xix, d_xiz,
                                                                            d_gammax, d_gammaz,
                                                                            mp->d_hprime_xx,
                                                                            mp->d_hprimewgll_xx,
                                                                            mp->d_wxgll,
                                                                            d_rhostore,
                                                                            mp->d_e1_acous,
                                                                            mp->d_A_newmark_acous,
                                                                            mp->d_B_newmark_acous,
                                                                            mp->d_sum_forces_old);
    }
    if (compute_wavefield_2) {
      Kernel_2_viscoacoustic_impl<3><<<grid,threads,0,mp->compute_stream>>>(nb_blocks_to_compute,
                                                                            d_ibool,
                                                                            mp->d_phase_ispec_inner_acoustic,
                                                                            mp->num_phase_ispec_acoustic,
                                                                            d_iphase,
                                                                            mp->d_b_potential_acoustic, mp->d_b_potential_dot_dot_acoustic,
                                                                            d_xix, d_xiz,
                                                                            d_gammax, d_gammaz,
                                                                            mp->d_hprime_xx,
                                                                            mp->d_hprimewgll_xx,
                                                                            mp->d_wxgll,
                                                                            d_rhostore,
                                                                            mp->d_b_e1_acous,
                                                                            mp->d_A_newmark_acous,
                                                                            mp->d_B_newmark_acous,
                                                                            mp->d_b_sum_forces_old);
    }
  } // ATTENUATION_VISCOACOUSTIC



  // Cuda timing
  if (CUDA_TIMING) {
    realw flops,time;
    stop_timing_cuda(&start,&stop,"Kernel_2_acoustic_impl",&time);
    // time in seconds
    time = time / 1000.;
    flops = 15559 * nb_blocks_to_compute;
    printf("  performance: %f GFlop/s\n", flops/time * 1.e-9);
  }

#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING
  exit_on_cuda_error("kernel Kernel_2");
#endif
}

/* ----------------------------------------------------------------------------------------------- */

// main compute_forces_acoustic CUDA routine

/* ----------------------------------------------------------------------------------------------- */

extern "C"
void FC_FUNC_(compute_forces_acoustic_cuda,
              COMPUTE_FORCES_ACOUSTIC_CUDA)(long* Mesh_pointer,
                                            int* iphase,
                                            int* nspec_outer_acoustic,
                                            int* nspec_inner_acoustic,
                                            int* ATTENUATION_VISCOACOUSTIC,
                                            int* compute_wavefield_1,
                                            int* compute_wavefield_2) {
  TRACE("compute_forces_acoustic_cuda");

  Mesh* mp = (Mesh*)(*Mesh_pointer); // get Mesh from fortran integer wrapper
  int num_elements;

  if (*iphase == 1)
    num_elements = *nspec_outer_acoustic;
  else
    num_elements = *nspec_inner_acoustic;

  // checks if anything to do
  if (num_elements == 0) return;

  // no mesh coloring: uses atomic updates
  Kernel_2_acoustic(num_elements, mp, *iphase,
                    mp->d_ibool,
                    mp->d_xix,mp->d_xiz,
                    mp->d_gammax,mp->d_gammaz,
                    mp->d_rhostore,
                    *ATTENUATION_VISCOACOUSTIC,
                    *compute_wavefield_1,
                    *compute_wavefield_2);

}

/* ----------------------------------------------------------------------------------------------- */

/* KERNEL for enforce free surface */

/* ----------------------------------------------------------------------------------------------- */


__global__ void enforce_free_surface_cuda_kernel(realw_p potential_acoustic,
                                                 realw_p potential_dot_acoustic,
                                                 realw_p potential_dot_dot_acoustic,
                                                 const int num_free_surface_faces,
                                                 const int* free_surface_ispec,
                                                 const int* free_surface_ij,
                                                 const int* d_ibool,
                                                 const int* ispec_is_acoustic) {
  // gets spectral element face id
  int iface = blockIdx.x + gridDim.x*blockIdx.y;

  // for all faces on free surface
  if (iface < num_free_surface_faces) {

    int ispec = free_surface_ispec[iface]-1;

    // checks if element is in acoustic domain
    if (ispec_is_acoustic[ispec]) {

      // gets global point index
      int igll = threadIdx.x + threadIdx.y*blockDim.x;

      int i = free_surface_ij[INDEX3(NDIM,NGLLX,0,igll,iface)] - 1; // (1,igll,iface)
      int j = free_surface_ij[INDEX3(NDIM,NGLLX,1,igll,iface)] - 1;

      int iglob = d_ibool[INDEX3_PADDED(NGLLX,NGLLX,i,j,ispec)] - 1;

      // sets potentials to zero at free surface
      potential_acoustic[iglob] = 0.f;
      potential_dot_acoustic[iglob] = 0.f;
      potential_dot_dot_acoustic[iglob] = 0.f;
    }
  }
}


/* ----------------------------------------------------------------------------------------------- */

extern "C"
void FC_FUNC_(acoustic_enforce_free_surf_cuda,
              ACOUSTIC_ENFORCE_FREE_SURF_CUDA)(long* Mesh_pointer,int* compute_wavefield_1,int* compute_wavefield_2) {

  TRACE("acoustic_enforce_free_surf_cuda");

  Mesh* mp = (Mesh*)(*Mesh_pointer); //get mesh pointer out of fortran integer container

  // does not absorb free surface, thus we enforce the potential to be zero at surface

  // checks if anything to do
  if (mp->num_free_surface_faces == 0) return;

  // block sizes
  int num_blocks_x, num_blocks_y;
  get_blocks_xy(mp->num_free_surface_faces,&num_blocks_x,&num_blocks_y);

  dim3 grid(num_blocks_x,num_blocks_y,1);
  dim3 threads(NGLLX,1,1);


  // sets potentials to zero at free surface
  if (*compute_wavefield_1) {
  enforce_free_surface_cuda_kernel<<<grid,threads,0,mp->compute_stream>>>(mp->d_potential_acoustic,
                                                                          mp->d_potential_dot_acoustic,
                                                                          mp->d_potential_dot_dot_acoustic,
                                                                          mp->num_free_surface_faces,
                                                                          mp->d_free_surface_ispec,
                                                                          mp->d_free_surface_ijk,
                                                                          mp->d_ibool,
                                                                          mp->d_ispec_is_acoustic);
  }
  // for backward/reconstructed potentials
  if (*compute_wavefield_2) {
    enforce_free_surface_cuda_kernel<<<grid,threads,0,mp->compute_stream>>>(mp->d_b_potential_acoustic,
                                                                            mp->d_b_potential_dot_acoustic,
                                                                            mp->d_b_potential_dot_dot_acoustic,
                                                                            mp->num_free_surface_faces,
                                                                            mp->d_free_surface_ispec,
                                                                            mp->d_free_surface_ijk,
                                                                            mp->d_ibool,
                                                                            mp->d_ispec_is_acoustic);
  }

#ifdef ENABLE_VERY_SLOW_ERROR_CHECKING
  exit_on_cuda_error("enforce_free_surface_cuda");
#endif
}


