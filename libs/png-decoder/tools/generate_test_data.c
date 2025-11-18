/* Test PNG Generator for PNG Decoder
 * Generates minimal test PNG files using LodePNG with filter control
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "lodepng/lodepng.h"

/* PCG32 PRNG Implementation */
typedef uint64_t pcg32_state_t;

/* PCG32 constants */
#define PCG32_MULTIPLIER  6364136223846793005ULL
#define PCG32_INCREMENT   3877204661ULL

void pcg32_srandom_r(pcg32_state_t *state, uint64_t seed) {
    *state = seed + PCG32_INCREMENT;
}

uint32_t pcg32_random_r(pcg32_state_t *state) {
    uint64_t oldstate = *state;
    *state = oldstate * PCG32_MULTIPLIER + PCG32_INCREMENT;
    uint32_t xorshifted = (uint32_t)(((oldstate >> 18u) ^ oldstate) >> 27u);
    uint32_t rot = (uint32_t)(oldstate >> 59u);
    return (xorshifted >> rot) | (xorshifted << (32u - rot));
}

/* Encode PNG with filter type specification */
unsigned encode_png_with_filter(
    const char* filename,
    const unsigned char* image,
    unsigned width,
    unsigned height,
    LodePNGFilterStrategy filter_strategy)
{
    LodePNGState state;
    lodepng_state_init(&state);

    /* CRITICAL: Disable auto_convert and explicitly set color type to grayscale */
    /* Otherwise, LodePNG will automatically choose RGBA or Palette */
    state.encoder.auto_convert = 0;
    state.info_raw.colortype = LCT_GREY;
    state.info_raw.bitdepth = 8;
    state.info_png.color.colortype = LCT_GREY;
    state.info_png.color.bitdepth = 8;

    /* Ensure filter strategy is applied even for grayscale images */
    state.encoder.filter_palette_zero = 0;
    state.encoder.filter_strategy = filter_strategy;

    unsigned char* png_data = NULL;
    size_t png_size = 0;
    unsigned error = lodepng_encode(&png_data, &png_size,
                                     image, width, height, &state);

    if(!error) {
        error = lodepng_save_file(png_data, png_size, filename);
    }

    free(png_data);
    lodepng_state_cleanup(&state);
    return error;
}

/* Generate 1x1 grayscale image with gray value 128 */
void generate_1x1_grayscale(void) {
    unsigned char image_data[1] = { 128 };
    const char* filename = "../test-data/1x1_grayscale.png";

    unsigned error = lodepng_encode_file(
        filename,
        image_data,
        1, 1,
        LCT_GREY,
        8
    );

    if (error) {
        printf("Error encoding 1x1_grayscale: %u (%s)\n",
               error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);
}

/* Generate 8x8 grayscale gradient with specified filter */
void generate_8x8_grayscale(LodePNGFilterStrategy filter_strategy, const char* filter_name) {
    unsigned width = 8, height = 8;
    unsigned char image_data[8 * 8];

    /* Create gradient pattern: each row has same gray value */
    /* Row 0: 0, Row 1: 32, Row 2: 64, ..., Row 7: 224 */
    for (unsigned y = 0; y < height; y++) {
        unsigned char gray_value = (unsigned char)(y * 32);
        for (unsigned x = 0; x < width; x++) {
            image_data[y * width + x] = gray_value;
        }
    }

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/8x8_gray_filter_%s.png", filter_name);

    unsigned error = encode_png_with_filter(
        filename,
        image_data,
        width, height,
        filter_strategy
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);
}

/* Generate 16x16 grayscale gradient with specified filter */
void generate_16x16_grayscale(LodePNGFilterStrategy filter_strategy, const char* filter_name) {
    unsigned width = 16, height = 16;
    unsigned char image_data[16 * 16];

    /* Create gradient pattern: each row has same gray value */
    /* Row 0: 0, Row 1: 16, Row 2: 32, ..., Row 15: 240 */
    for (unsigned y = 0; y < height; y++) {
        unsigned char gray_value = (unsigned char)(y * 16);
        for (unsigned x = 0; x < width; x++) {
            image_data[y * width + x] = gray_value;
        }
    }

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/16x16_gray_filter_%s.png", filter_name);

    unsigned error = encode_png_with_filter(
        filename,
        image_data,
        width, height,
        filter_strategy
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);
}

/* Encode PNG with filter type specification for RGB color type */
unsigned encode_rgb_png_with_filter(
    const char* filename,
    const unsigned char* image,
    unsigned width,
    unsigned height,
    LodePNGFilterStrategy filter_strategy)
{
    LodePNGState state;
    lodepng_state_init(&state);

    /* Disable auto_convert and explicitly set color type to RGB */
    state.encoder.auto_convert = 0;
    state.info_raw.colortype = LCT_RGB;
    state.info_raw.bitdepth = 8;
    state.info_png.color.colortype = LCT_RGB;
    state.info_png.color.bitdepth = 8;

    /* Ensure filter strategy is applied */
    state.encoder.filter_palette_zero = 0;
    state.encoder.filter_strategy = filter_strategy;

    unsigned char* png_data = NULL;
    size_t png_size = 0;
    unsigned error = lodepng_encode(&png_data, &png_size,
                                     image, width, height, &state);

    if(!error) {
        error = lodepng_save_file(png_data, png_size, filename);
    }

    free(png_data);
    lodepng_state_cleanup(&state);
    return error;
}

/* Generate 8x8 RGB checkerboard pattern with specified filter */
void generate_8x8_rgb_checkerboard(LodePNGFilterStrategy filter_strategy, const char* filter_name) {
    unsigned width = 8, height = 8;
    unsigned char image_data[8 * 8 * 3];  /* RGB = 3 bytes per pixel */

    /* Create checkerboard pattern: alternate red and blue */
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 3;
            if ((x + y) % 2 == 0) {
                /* Red */
                image_data[idx] = 255;
                image_data[idx + 1] = 0;
                image_data[idx + 2] = 0;
            } else {
                /* Blue */
                image_data[idx] = 0;
                image_data[idx + 1] = 0;
                image_data[idx + 2] = 255;
            }
        }
    }

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/8x8_rgb_checkerboard_filter_%s.png", filter_name);

    unsigned error = encode_rgb_png_with_filter(
        filename,
        image_data,
        width, height,
        filter_strategy
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);
}

/* Generate 16x16 RGB gradient with specified filter */
void generate_16x16_rgb_gradient(LodePNGFilterStrategy filter_strategy, const char* filter_name) {
    unsigned width = 16, height = 16;
    unsigned char image_data[16 * 16 * 3];  /* RGB = 3 bytes per pixel */

    /* Create RGB gradient: R increases horizontally, G increases vertically, B stays constant */
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 3;
            image_data[idx] = (unsigned char)(x * 16);      /* R: 0-240 */
            image_data[idx + 1] = (unsigned char)(y * 16);  /* G: 0-240 */
            image_data[idx + 2] = 128;                       /* B: constant */
        }
    }

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/16x16_rgb_gradient_filter_%s.png", filter_name);

    unsigned error = encode_rgb_png_with_filter(
        filename,
        image_data,
        width, height,
        filter_strategy
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);
}

/* Encode PNG with filter type specification for RGBA color type */
unsigned encode_rgba_png_with_filter(
    const char* filename,
    const unsigned char* image,
    unsigned width,
    unsigned height,
    LodePNGFilterStrategy filter_strategy)
{
    LodePNGState state;
    lodepng_state_init(&state);

    /* Disable auto_convert and explicitly set color type to RGBA */
    state.encoder.auto_convert = 0;
    state.info_raw.colortype = LCT_RGBA;
    state.info_raw.bitdepth = 8;
    state.info_png.color.colortype = LCT_RGBA;
    state.info_png.color.bitdepth = 8;

    /* Ensure filter strategy is applied */
    state.encoder.filter_palette_zero = 0;
    state.encoder.filter_strategy = filter_strategy;

    unsigned char* png_data = NULL;
    size_t png_size = 0;
    unsigned error = lodepng_encode(&png_data, &png_size,
                                     image, width, height, &state);

    if(!error) {
        error = lodepng_save_file(png_data, png_size, filename);
    }

    free(png_data);
    lodepng_state_cleanup(&state);
    return error;
}

/* Generate 8x8 RGBA checkerboard pattern with specified filter */
void generate_8x8_rgba_checkerboard(LodePNGFilterStrategy filter_strategy, const char* filter_name) {
    unsigned width = 8, height = 8;
    unsigned char image_data[8 * 8 * 4];  /* RGBA = 4 bytes per pixel */

    /* Create checkerboard pattern: alternate red (opaque) and blue (semi-transparent) */
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 4;
            if ((x + y) % 2 == 0) {
                /* Red (fully opaque) */
                image_data[idx] = 255;      /* R */
                image_data[idx + 1] = 0;    /* G */
                image_data[idx + 2] = 0;    /* B */
                image_data[idx + 3] = 255;  /* A */
            } else {
                /* Blue (semi-transparent) */
                image_data[idx] = 0;        /* R */
                image_data[idx + 1] = 0;    /* G */
                image_data[idx + 2] = 255;  /* B */
                image_data[idx + 3] = 128;  /* A: 50% */
            }
        }
    }

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/8x8_rgba_checkerboard_filter_%s.png", filter_name);

    unsigned error = encode_rgba_png_with_filter(
        filename,
        image_data,
        width, height,
        filter_strategy
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);
}

/* Generate 16x16 RGBA gradient with specified filter */
void generate_16x16_rgba_gradient(LodePNGFilterStrategy filter_strategy, const char* filter_name) {
    unsigned width = 16, height = 16;
    unsigned char image_data[16 * 16 * 4];  /* RGBA = 4 bytes per pixel */

    /* Create RGBA gradient: R increases horizontally, G increases vertically, B stays constant, A varies */
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 4;
            image_data[idx] = (unsigned char)(x * 16);      /* R: 0-240 */
            image_data[idx + 1] = (unsigned char)(y * 16);  /* G: 0-240 */
            image_data[idx + 2] = 128;                       /* B: constant */
            image_data[idx + 3] = (unsigned char)(x * 16);  /* A: 0-240 (varies with R) */
        }
    }

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/16x16_rgba_gradient_filter_%s.png", filter_name);

    unsigned error = encode_rgba_png_with_filter(
        filename,
        image_data,
        width, height,
        filter_strategy
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);
}

/* Pattern generation helper functions */

void fill_gradient_rgb(unsigned char *image, unsigned width, unsigned height) {
    /* X軸でR増加、Y軸でG増加、B固定 */
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 3;
            image[idx] = (unsigned char)((x * 256) / width);      /* R: 0-255 */
            image[idx + 1] = (unsigned char)((y * 256) / height); /* G: 0-255 */
            image[idx + 2] = 128;                                  /* B: constant */
        }
    }
}

void fill_checkerboard_rgb(unsigned char *image, unsigned width, unsigned height, unsigned block_size) {
    /* block_size x block_size ブロックの黒/白チェッカーボード */
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 3;
            unsigned block_x = x / block_size;
            unsigned block_y = y / block_size;
            unsigned char color = ((block_x + block_y) % 2 == 0) ? 255 : 0;
            image[idx] = color;     /* R */
            image[idx + 1] = color; /* G */
            image[idx + 2] = color; /* B */
        }
    }
}

void fill_noise_rgba(unsigned char *image, unsigned width, unsigned height, uint64_t seed) {
    /* PCG32による再現可能なノイズ */
    pcg32_state_t rng;
    pcg32_srandom_r(&rng, seed);

    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 4;
            uint32_t random_val = pcg32_random_r(&rng);
            image[idx] = (unsigned char)(random_val >> 24);        /* R */
            image[idx + 1] = (unsigned char)(random_val >> 16);    /* G */
            image[idx + 2] = (unsigned char)(random_val >> 8);     /* B */
            image[idx + 3] = (unsigned char)(random_val & 0xFF);   /* A */
        }
    }
}

/* Large image generation functions for benchmarking */

void generate_256x256_rgb_gradient(void) {
    unsigned width = 256, height = 256;
    unsigned char *image_data = (unsigned char *)malloc(width * height * 3);

    fill_gradient_rgb(image_data, width, height);

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/256x256_rgb_gradient_filter_none.png");

    unsigned error = encode_rgb_png_with_filter(
        filename,
        image_data,
        width, height,
        LFS_ZERO
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
    } else {
        printf("Generated: %s\n", filename);
    }

    free(image_data);
}

void generate_256x256_rgba_noise(void) {
    unsigned width = 256, height = 256;
    unsigned char *image_data = (unsigned char *)malloc(width * height * 4);

    fill_noise_rgba(image_data, width, height, 12345);

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/256x256_rgba_noise_filter_paeth.png");

    unsigned error = encode_rgba_png_with_filter(
        filename,
        image_data,
        width, height,
        LFS_FOUR
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
    } else {
        printf("Generated: %s\n", filename);
    }

    free(image_data);
}

void generate_512x512_rgb_checkerboard(void) {
    unsigned width = 512, height = 512;
    unsigned char *image_data = (unsigned char *)malloc(width * height * 3);

    fill_checkerboard_rgb(image_data, width, height, 32);

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/512x512_rgb_checkerboard_filter_sub.png");

    unsigned error = encode_rgb_png_with_filter(
        filename,
        image_data,
        width, height,
        LFS_ONE
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
    } else {
        printf("Generated: %s\n", filename);
    }

    free(image_data);
}

void generate_512x512_rgba_noise(void) {
    unsigned width = 512, height = 512;
    unsigned char *image_data = (unsigned char *)malloc(width * height * 4);

    fill_noise_rgba(image_data, width, height, 54321);

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/512x512_rgba_noise_filter_average.png");

    unsigned error = encode_rgba_png_with_filter(
        filename,
        image_data,
        width, height,
        LFS_THREE
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
    } else {
        printf("Generated: %s\n", filename);
    }

    free(image_data);
}

void generate_1024x1024_rgb_gradient(void) {
    unsigned width = 1024, height = 1024;
    unsigned char *image_data = (unsigned char *)malloc(width * height * 3);

    fill_gradient_rgb(image_data, width, height);

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/1024x1024_rgb_gradient_filter_sub.png");

    unsigned error = encode_rgb_png_with_filter(
        filename,
        image_data,
        width, height,
        LFS_ONE
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
    } else {
        printf("Generated: %s\n", filename);
    }

    free(image_data);
}

void generate_1920x1080_rgba_gradient(void) {
    unsigned width = 1920, height = 1080;
    unsigned char *image_data = (unsigned char *)malloc(width * height * 4);

    /* X軸でR増加、Y軸でG増加、B固定、AはXと同じ */
    for (unsigned y = 0; y < height; y++) {
        for (unsigned x = 0; x < width; x++) {
            unsigned idx = (y * width + x) * 4;
            image_data[idx] = (unsigned char)((x * 256) / width);      /* R: 0-255 */
            image_data[idx + 1] = (unsigned char)((y * 256) / height); /* G: 0-255 */
            image_data[idx + 2] = 128;                                  /* B: constant */
            image_data[idx + 3] = (unsigned char)((x * 256) / width);  /* A: same as R */
        }
    }

    char filename[256];
    snprintf(filename, sizeof(filename), "../test-data/1920x1080_rgba_gradient_filter_average.png");

    unsigned error = encode_rgba_png_with_filter(
        filename,
        image_data,
        width, height,
        LFS_THREE
    );

    if (error) {
        printf("Error encoding %s: %u (%s)\n",
               filename, error, lodepng_error_text(error));
    } else {
        printf("Generated: %s\n", filename);
    }

    free(image_data);
}

int main(void) {
    /* Create test-data directory if it doesn't exist */
    system("mkdir -p ../test-data");

    printf("Generating test PNG files...\n\n");

    /* 1x1 grayscale (existing) */
    generate_1x1_grayscale();

    printf("\n");

    /* 8x8 grayscale with different filters */
    printf("\n=== 8x8 Grayscale ===\n");
    generate_8x8_grayscale(LFS_ZERO, "none");
    printf("\n");
    generate_8x8_grayscale(LFS_ONE, "sub");
    printf("\n");
    generate_8x8_grayscale(LFS_TWO, "up");
    printf("\n");
    generate_8x8_grayscale(LFS_THREE, "average");
    printf("\n");
    generate_8x8_grayscale(LFS_FOUR, "paeth");

    printf("\n");

    /* 16x16 grayscale with different filters */
    printf("\n=== 16x16 Grayscale ===\n");
    generate_16x16_grayscale(LFS_ZERO, "none");
    printf("\n");
    generate_16x16_grayscale(LFS_ONE, "sub");
    printf("\n");
    generate_16x16_grayscale(LFS_TWO, "up");
    printf("\n");
    generate_16x16_grayscale(LFS_THREE, "average");
    printf("\n");
    generate_16x16_grayscale(LFS_FOUR, "paeth");

    printf("\n");

    /* 8x8 RGB checkerboard with different filters */
    printf("\n=== 8x8 RGB Checkerboard ===\n");
    generate_8x8_rgb_checkerboard(LFS_ZERO, "none");
    printf("\n");
    generate_8x8_rgb_checkerboard(LFS_ONE, "sub");
    printf("\n");
    generate_8x8_rgb_checkerboard(LFS_TWO, "up");
    printf("\n");
    generate_8x8_rgb_checkerboard(LFS_THREE, "average");
    printf("\n");
    generate_8x8_rgb_checkerboard(LFS_FOUR, "paeth");

    printf("\n");

    /* 16x16 RGB gradient with different filters */
    printf("\n=== 16x16 RGB Gradient ===\n");
    generate_16x16_rgb_gradient(LFS_ZERO, "none");
    printf("\n");
    generate_16x16_rgb_gradient(LFS_ONE, "sub");
    printf("\n");
    generate_16x16_rgb_gradient(LFS_TWO, "up");
    printf("\n");
    generate_16x16_rgb_gradient(LFS_THREE, "average");
    printf("\n");
    generate_16x16_rgb_gradient(LFS_FOUR, "paeth");

    printf("\n");

    /* 8x8 RGBA checkerboard with different filters */
    printf("\n=== 8x8 RGBA Checkerboard ===\n");
    generate_8x8_rgba_checkerboard(LFS_ZERO, "none");
    printf("\n");
    generate_8x8_rgba_checkerboard(LFS_ONE, "sub");
    printf("\n");
    generate_8x8_rgba_checkerboard(LFS_TWO, "up");
    printf("\n");
    generate_8x8_rgba_checkerboard(LFS_THREE, "average");
    printf("\n");
    generate_8x8_rgba_checkerboard(LFS_FOUR, "paeth");

    printf("\n");

    /* 16x16 RGBA gradient with different filters */
    printf("\n=== 16x16 RGBA Gradient ===\n");
    generate_16x16_rgba_gradient(LFS_ZERO, "none");
    printf("\n");
    generate_16x16_rgba_gradient(LFS_ONE, "sub");
    printf("\n");
    generate_16x16_rgba_gradient(LFS_TWO, "up");
    printf("\n");
    generate_16x16_rgba_gradient(LFS_THREE, "average");
    printf("\n");
    generate_16x16_rgba_gradient(LFS_FOUR, "paeth");

    /* Large images for benchmarking */
    printf("\n");
    printf("\n=== Large Images for Benchmarking ===\n");
    generate_256x256_rgb_gradient();
    printf("\n");
    generate_256x256_rgba_noise();
    printf("\n");
    generate_512x512_rgb_checkerboard();
    printf("\n");
    generate_512x512_rgba_noise();
    printf("\n");
    generate_1024x1024_rgb_gradient();
    printf("\n");
    generate_1920x1080_rgba_gradient();

    printf("\n\nTest data generation complete!\n");

    return 0;
}
