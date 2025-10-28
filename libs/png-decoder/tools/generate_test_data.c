/* Test PNG Generator for PNG Decoder
 * Generates minimal test PNG files using LodePNG
 */

#include <stdio.h>
#include <stdint.h>
#include "lodepng/lodepng.h"

/* Generate 1x1 grayscale image with gray value 128 */
void generate_1x1_grayscale(void) {
    unsigned char image_data[1] = { 128 };  /* 1 pixel, grayscale value 128 */
    const char* filename = "../test-data/1x1_grayscale.png";

    unsigned error = lodepng_encode_file(
        filename,
        image_data,
        1, 1,           /* width, height */
        LCT_GREY,       /* color type: grayscale */
        8               /* bit depth: 8-bit */
    );

    if (error) {
        printf("Error encoding 1x1_grayscale: %u (%s)\n",
               error, lodepng_error_text(error));
        return;
    }

    printf("Generated: %s\n", filename);

    /* Output expected values in Zig format */
    printf("\n// Expected value for 1x1_grayscale.png\n");
    printf("pub const grayscale_1x1_expected = [_]u32{\n");
    printf("    0x808080FF,  // gray=128 -> RGBA8888 (R=128, G=128, B=128, A=255)\n");
    printf("};\n");
}

int main(void) {
    /* Create test-data directory if it doesn't exist */
    system("mkdir -p ../test-data");

    printf("Generating test PNG files...\n\n");
    generate_1x1_grayscale();
    printf("\nTest data generation complete!\n");

    return 0;
}
