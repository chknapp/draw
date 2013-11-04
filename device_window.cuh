#ifndef _DEVICE_WINDOW_CUH_
#define _DEVICE_WINDOW_CUH_

#include <GL/glew.h>
#include <GL/glfw.h>
#include <cuda_gl_interop.h>

#include <thrust/device_vector.h>
#include <thrust/transform.h>

#include "colormap.cuh"

namespace draw
{
void cudaGlfwInit( int width, int height)
{
    //initialize glfw
    if( !glfwInit()) { std::cerr << "ERROR: glfw couldn't initialize.\n";}
    int major, minor, rev;
    glfwGetVersion( &major, &minor, &rev);
    std::cout << "Using GLFW version   "<<major<<"."<<minor<<"."<<rev<<"\n";
    // create window and OpenGL context bound to it
    if( !glfwOpenWindow( width, height,  0,0,0,  0,0,0, GLFW_WINDOW))
    { 
        std::cerr << "ERROR: glfw couldn't open window!\n";
    } 
    std::cout << "Using OpenGL version "
        <<glfwGetWindowParam( GLFW_OPENGL_VERSION_MAJOR)<<"."
        <<glfwGetWindowParam( GLFW_OPENGL_VERSION_MINOR)<<"\n";
    //initialize glew (needed for GLbuffer allocation)
    GLenum err = glewInit();
    if (GLEW_OK != err)
    {
          /* Problem: glewInit failed, something is seriously wrong. */
        std::cerr << "Error: " << glewGetErrorString(err) << "\n";
        return;
    }
    std::cout << "Using GLEW version   " << glewGetString(GLEW_VERSION) <<"\n";

    int device;
    cudaGetDevice( &device);
    std::cout << "Using device number  "<<device<<"\n";
    cudaGLSetGLDevice( device ); 

    cudaError_t error;
    error = cudaGetLastError();
    if( error != cudaSuccess){
        std::cout << cudaGetErrorString( error);}

    glEnable(GL_TEXTURE_2D);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
}

GLuint allocateGlBuffer( unsigned N)
{
    GLuint bufferID;
    glGenBuffers( 1, &bufferID);
    glBindBuffer( GL_PIXEL_UNPACK_BUFFER, bufferID);
    // the buffer shall contain a texture 
    glBufferData( GL_PIXEL_UNPACK_BUFFER, N*sizeof(float), NULL, GL_DYNAMIC_DRAW);
    return bufferID;
}

//N should be 3*Nx*Ny
cudaGraphicsResource* allocateCudaGlBuffer( unsigned N )
{
    cudaGraphicsResource* resource;
    GLuint bufferID = allocateGlBuffer( N);
    //register the resource i.e. tell CUDA and OpenGL that buffer is used by both
    cudaError_t error;
    error = cudaGraphicsGLRegisterBuffer( &resource, bufferID, cudaGraphicsRegisterFlagsWriteDiscard); 
    if( error != cudaSuccess){
        std::cout << cudaGetErrorString( error); return NULL;}
    return resource;
}


void freeCudaGlBuffer( cudaGraphicsResource* resource)
{
    cudaGraphicsUnregisterResource( resource);
}

template< class T>
void mapColors( const dg::ColorMapRedBlueExt& map, const thrust::device_vector<T>& x, cudaGraphicsResource* resource)
{
    dg::Color* d_buffer;
    size_t size;
    //Map resource into CUDA memory space
    cudaGraphicsMapResources( 1, &resource, 0);
    // get a pointer to the mapped resource
    cudaGraphicsResourceGetMappedPointer( (void**)&d_buffer, &size, resource);
#ifdef DG_DEBUG
    assert( x.size() == size/3/sizeof(float));
#endif //DG_DEBUG
    thrust::transform( x.begin(), x.end(), thrust::device_pointer_cast( d_buffer), map);
    cudaThreadSynchronize();
    //unmap the resource before OpenGL uses it
    cudaGraphicsUnmapResources( 1, &resource, 0);
}

void loadTexture( int width, int height)
{
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, width, height, 0, GL_RGB, GL_FLOAT, NULL);
}

void drawQuad( double x0, double x1, double y0, double y1)
{
    // image comes from UNPACK_BUFFER on device
    glLoadIdentity();
    glBegin(GL_QUADS);
        glTexCoord2f(0.0f, 0.0f); glVertex2f( x0, y0);
        glTexCoord2f(1.0f, 0.0f); glVertex2f( x1, y0);
        glTexCoord2f(1.0f, 1.0f); glVertex2f( x1, y1);
        glTexCoord2f(0.0f, 1.0f); glVertex2f( x0, y1);
    glEnd();
}

void GLFWCALL WindowResize( int w, int h)
{
    // map coordinates to the whole window
    glViewport( 0, 0, (GLsizei) w, h);
}

/**
 * @brief Draw a Window that uses data from your cuda computations

 * The aim of this class is to provide an interface to make 
 * the plot of a 2D vector during CUDA computations as simple as possible. 
 * Uses glfw and the cuda_gl_interop functionality
 * @note not tested yet
 */
struct DeviceWindow
{
    /**
     * @brief Open a window
     *
     * @param width in pixel
     * @param height in pixel
     */
    DeviceWindow( int width, int height) { 
        resource = NULL;
        Nx_ = Ny_ = 0;
        bufferID = 0;
        cudaGlfwInit( width, height);
        glClearColor( 0.f, 0.f, 1.f, 0.f);
        glClear(GL_COLOR_BUFFER_BIT);
        glfwSetWindowSizeCallback( WindowResize);
    }
    /**
     * @brief free resources
     */
    ~DeviceWindow( ) {
        if( resource != NULL){
            cudaGraphicsUnregisterResource( resource); 
            //free the opengl buffer
            glDeleteBuffers( 1, &bufferID);
        }
        //terminate glfw
        glfwTerminate();
    }
    /**
     * @brief Draw a 2D field in the open window
     *
     * The first element of the given vector corresponds to the bottom left corner. (i.e. the 
     * origin of a 2D coordinate system) Successive
     * elements correspond to points from left to right and from bottom to top.
     * @note If multiplot is set the field will be drawn in the current active 
     * box. When all boxes are full the picture will be drawn on screen and 
     * the top left box is active again. The title is reset.
     * @tparam T The datatype of your elements
     * @param x Elements to be drawn lying on the device
     * @param Nx # of x points to be used ( the width)
     * @param Ny # of y points to be used ( the height)
     * @param map The colormap used to compute color from elements
     */
    template< class T>
    void draw( const thrust::device_vector<T>& x, unsigned Nx, unsigned Ny, dg::ColorMapRedBlueExt& map)
    {
        if( Nx != Nx_ || Ny != Ny_) {
            Nx_ = Nx; Ny_ = Ny;
            cudaGraphicsUnregisterResource( resource);
            std::cout << "Allocate resources for drawing!\n";
            //free opengl buffer
            GLint id; 
            glGetIntegerv( GL_PIXEL_UNPACK_BUFFER_BINDING, &id);
            bufferID = (GLuint)id;
            glDeleteBuffers( 1, &bufferID);
            //allocate new buffer
            resource = allocateCudaGlBuffer( 3*Nx*Ny);
            glGetIntegerv( GL_PIXEL_UNPACK_BUFFER_BINDING, &id);
            bufferID = (GLuint)id;
        }

        mapColors( map, x, resource);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, Nx, Ny, 0, GL_RGB, GL_FLOAT, NULL);
        glLoadIdentity();
        float x0 = -1, x1 = 1, y0 = -1, y1 = 1;
        glBegin(GL_QUADS); 
            glTexCoord2f(0.0f, 0.0f); glVertex2f( x0, y0);
            glTexCoord2f(1.0f, 0.0f); glVertex2f( x1, y0);
            glTexCoord2f(1.0f, 1.0f); glVertex2f( x1, y1);
            glTexCoord2f(0.0f, 1.0f); glVertex2f( x0, y1);
        glEnd();
        glfwSwapBuffers();
    }
  private:
    DeviceWindow( const DeviceWindow&);
    DeviceWindow& operator=( const DeviceWindow&);
    GLuint bufferID;
    cudaGraphicsResource* resource;  
    unsigned Nx_, Ny_;
};

} //namespace draw

#endif//_DEVICE_WINDOW_CUH_
