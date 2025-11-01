/* Test PNG Generator for PNG Decoder
 * Generates minimal test PNG files using LodePNG with filter control
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "lodepng/lodepng.h"

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

    printf("\n// Expected value for 1x1_grayscale.png\n");
    printf("pub const grayscale_1x1_expected = [_]u32{\n");
    printf("    0x808080FF,  // gray=128 -> RGBA8888\n");
    printf("};\n");
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

    /* Output expected values in Zig format */
    printf("\n// Expected values for %s\n", filename);
    printf("pub const grayscale_8x8_filter_%s_expected = [_]u32{\n", filter_name);
    for (unsigned y = 0; y < height; y++) {
        unsigned char gray_value = (unsigned char)(y * 32);
        printf("    ");
        for (unsigned x = 0; x < width; x++) {
            printf("0x%02X%02X%02XFF,", gray_value, gray_value, gray_value);
            if (x < width - 1) printf(" ");
        }
        printf("\n");
    }
    printf("};\n");
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

    /* Output expected values in Zig format */
    printf("\n// Expected values for %s\n", filename);
    printf("pub const grayscale_16x16_filter_%s_expected = [_]u32{\n", filter_name);
    for (unsigned y = 0; y < height; y++) {
        unsigned char gray_value = (unsigned char)(y * 16);
        printf("    ");
        for (unsigned x = 0; x < width; x++) {
            printf("0x%02X%02X%02XFF,", gray_value, gray_value, gray_value);
            if (x < width - 1) printf(" ");
        }
        printf("\n");
    }
    printf("};\n");
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

    /* 16x16 grayscale with different filters */
    printf("\n=== 16x16 Grayscale ===\n");
    generate_16x16_grayscale(LFS_ZERO, "none");
    printf("\n");
    generate_16x16_grayscale(LFS_ONE, "sub");
    printf("\n");
    generate_16x16_grayscale(LFS_TWO, "up");

    printf("\n\nTest data generation complete!\n");

    return 0;
}
