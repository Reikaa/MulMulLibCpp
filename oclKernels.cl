#define BLOCK_SIZE 16
#define SCALAR 10
#define SCAL_THRESH 1e-10
#define MAX(a, b) (((a) > (b)) ? (a) : (b))

__kernel void matMul(
                __global float* A,
                __global int* Ascalings,
                __global float* B,
                __global int* Bscalings,
                __global float* C,
                __global int* Cscalings,
                int a_row_len,
                int a_round_row_len,
                int c_round_row_len,
                int row_bound,  // max real length of a row in C
                int col_bound,  // max real length of a column in C
                int a_offset,
                int b_offset,
                int c_offset)
{
    int wA = a_round_row_len;
    int wB = c_round_row_len;

    // Block index
    int bx = get_group_id(0);
    int by = get_group_id(1);

    // Thread index
    int tx = get_local_id(0);   // tx == col #
    int ty = get_local_id(1);   // ty == row #

    bool in_frame = false;
    if (tx < row_bound && ty < col_bound)
        in_frame = true;

    // Index of the first sub-matrix of A processed
    // by the block
    int aBegin = wA * BLOCK_SIZE * by;

    // Index of the last sub-matrix of A processed
    // by the block
    int aEnd   = aBegin + wA - 1;

    // Step size used to iterate through the
    // sub-matrices of A
    int aStep  = BLOCK_SIZE;

    // Index of the first sub-matrix of B processed
    // by the block
    int bBegin = BLOCK_SIZE * bx;

    // Step size used to iterate through the
    // sub-matrices of B
    int bStep  = BLOCK_SIZE * wB;

    float Csub_sig = 0.0f;
    int Csub_exp = 0;

    // Loop over all the sub-matrices of A and B
    // required to compute the block sub-matrix
    for (int a = aBegin, b = bBegin;
             a <= aEnd;
             a += aStep, b += bStep)
    {

        // Declaration of the local memory array As
        // used to store the sub-matrix of A
        __local float As[BLOCK_SIZE][BLOCK_SIZE];
        __local int Ascal_cache[BLOCK_SIZE][BLOCK_SIZE];

        // Declaration of the local memory array Bs
        // used to store the sub-matrix of B
        __local float Bs[BLOCK_SIZE][BLOCK_SIZE];
        __local int Bscal_cache[BLOCK_SIZE][BLOCK_SIZE];

        // Load the matrices from global memory
        // to local memory; each thread loads
        // one element of each matrix
        int A_index = a + wA * ty + tx;
        if ((A_index / wA) < col_bound && (A_index % wA) < a_row_len)
        {
            As[ty][tx] = A[a_offset + A_index];
            Ascal_cache[ty][tx] = Ascalings[a_offset + A_index];
        }
        else
        {
            As[ty][tx] = 0.0f;
            Ascal_cache[ty][tx] = 0;
        }

        int B_index = b + wB * ty + tx;
        if ((B_index / wB) < a_row_len && (B_index % wB) < row_bound)
        {
            Bs[ty][tx] = B[b_offset + B_index];
            Bscal_cache[ty][tx] = Bscalings[b_offset + B_index];
        }
        else
        {
            Bs[ty][tx] = 0.0f;
            Bscal_cache[ty][tx] = 0;
        }

        // Synchronize to make sure the matrices
        // are loaded
        barrier(CLK_LOCAL_MEM_FENCE);

        // Multiply the two matrices together;
        // each thread computes one element
        // of the block sub-matrix
        for (int k = 0; k < BLOCK_SIZE; ++k)
        {
            float a_sig = As[ty][k];
            int a_exp = Ascal_cache[ty][k];
            float b_sig = Bs[k][tx];
            int b_exp = Bscal_cache[k][tx];
            float c_sig = a_sig * b_sig;
            int c_exp = a_exp + b_exp;
            int new_exp = MAX(c_exp, Csub_exp);
            int c_sub_sig_local = Csub_sig * pow(   10.0f,
                                                    (float)new_exp -
                                                    (float)Csub_exp);
            c_sig = c_sig * pow(10.0f,
                                (float)new_exp -
                                (float)Csub_exp);
            Csub_sig = c_sub_sig_local + c_sig;
            Csub_exp = new_exp;

            //Csub_sig += c_sig;
            //Csub += c_sig * pow(10, c_exp - Cexp);
            // problem: Cexp will never change
            // problem: What should Cexp start as?
            // when should it move?
            //Csub += As[ty][k] * Bs[k][tx];
        }

        // Synchronize to make sure that the preceding
        // computation is done before loading two new
        // sub-matrices of A and B in the next iteration
        barrier(CLK_LOCAL_MEM_FENCE);

    }
    while (Csub_sig < SCAL_THRESH && Csub_sig > 0)
    {
        Csub_sig *= SCALAR;
        Csub_exp += 1;
    }
    while (Csub_sig > -1*SCAL_THRESH && Csub_sig < 0)
    {
        Csub_sig *= SCALAR;
        Csub_exp += 1;
    }
    while (Csub_sig > 1/SCAL_THRESH)
    {
        Csub_sig /= SCALAR;
        Csub_exp -= 1;
    }
    while (Csub_sig < -1/SCAL_THRESH)
    {
        Csub_sig /= SCALAR;
        Csub_exp -= 1;
    }

    // Write the block sub-matrix to device memory;
    // each thread writes one element
    int c = wB * BLOCK_SIZE * by + BLOCK_SIZE * bx;
    if (in_frame)
    {
        C[c_offset + c + wB * ty + tx] = Csub_sig;
        Cscalings[c_offset + c + wB * ty + tx] = Csub_exp;
    }
}
