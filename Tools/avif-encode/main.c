// avif-encode: writes a single-item AVIF (the layout every browser decodes) from raw RGBA pixels.
//
//   avif-encode <in.rgba> <width> <height> <quality 0-100> <speed 0-10> <out.avif> [premultiplied]
//
// Imager decodes the source with ImageIO into 8-bit sRGB RGBA and hands the buffer over; libavif
// with libaom does the AV1 encoding. Apple's own AVIF encoder splits anything larger than
// 512 px into a grid of tiles, which Firefox cannot display (Mozilla bug 1696090), so it isn't used
// for AVIF.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "avif/avif.h"

int main(int argc, char **argv) {
    if (argc < 7) {
        fprintf(stderr, "usage: avif-encode <in.rgba> <width> <height> <quality> <speed> <out.avif> [premultiplied]\n");
        return 2;
    }
    const char *inPath = argv[1];
    int width = atoi(argv[2]), height = atoi(argv[3]);
    int quality = atoi(argv[4]), speed = atoi(argv[5]);
    const char *outPath = argv[6];
    int premultiplied = argc > 7 && strcmp(argv[7], "premultiplied") == 0;
    if (width <= 0 || height <= 0) { fprintf(stderr, "bad dimensions\n"); return 2; }
    if (quality < 0) quality = 0;
    if (quality > 100) quality = 100;
    if (speed < 0) speed = 0;
    if (speed > 10) speed = 10;

    size_t bytes = (size_t)width * (size_t)height * 4;
    unsigned char *pixels = malloc(bytes);
    if (!pixels) { fprintf(stderr, "out of memory\n"); return 1; }
    FILE *in = fopen(inPath, "rb");
    if (!in || fread(pixels, 1, bytes, in) != bytes) { fprintf(stderr, "could not read %zu bytes of RGBA\n", bytes); return 1; }
    fclose(in);

    // Does the image use its alpha channel at all? If not, write an opaque file.
    int hasAlpha = 0;
    for (size_t i = 3; i < bytes; i += 4) { if (pixels[i] != 255) { hasAlpha = 1; break; } }

    // 4:2:0 for photographic content; 4:4:4 near the top of the scale, where chroma blur shows.
    avifPixelFormat format = quality >= 90 ? AVIF_PIXEL_FORMAT_YUV444 : AVIF_PIXEL_FORMAT_YUV420;
    avifImage *image = avifImageCreate(width, height, 8, format);
    if (!image) { fprintf(stderr, "could not create image\n"); return 1; }
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709;          // sRGB primaries
    image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;  // what browsers and libavif default to
    image->yuvRange = AVIF_RANGE_FULL;
    image->alphaPremultiplied = premultiplied ? AVIF_TRUE : AVIF_FALSE;

    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = AVIF_RGB_FORMAT_RGBA;
    rgb.depth = 8;
    rgb.alphaPremultiplied = premultiplied ? AVIF_TRUE : AVIF_FALSE;
    rgb.ignoreAlpha = hasAlpha ? AVIF_FALSE : AVIF_TRUE;
    rgb.pixels = pixels;
    rgb.rowBytes = (uint32_t)width * 4;
    avifResult result = avifImageRGBToYUV(image, &rgb);
    if (result != AVIF_RESULT_OK) { fprintf(stderr, "RGB to YUV failed: %s\n", avifResultToString(result)); return 1; }

    avifEncoder *encoder = avifEncoderCreate();
    if (!encoder) { fprintf(stderr, "could not create encoder\n"); return 1; }
    encoder->quality = quality;
    encoder->qualityAlpha = quality < 100 ? (quality + 100) / 2 : 100; // alpha edges deserve more bits
    encoder->speed = speed;
    encoder->maxThreads = 8;
    encoder->tileRowsLog2 = 0;
    encoder->tileColsLog2 = 0;
    encoder->autoTiling = AVIF_TRUE; // AV1-level tiles inside one frame; still a single AVIF item

    avifRWData output = AVIF_DATA_EMPTY;
    result = avifEncoderWrite(encoder, image, &output);
    if (result != AVIF_RESULT_OK) { fprintf(stderr, "encode failed: %s\n", avifResultToString(result)); return 1; }

    FILE *out = fopen(outPath, "wb");
    if (!out || fwrite(output.data, 1, output.size, out) != output.size) { fprintf(stderr, "could not write %s\n", outPath); return 1; }
    fclose(out);
    fprintf(stderr, "wrote %zu bytes (%s, quality %d, speed %d)\n", output.size, hasAlpha ? "with alpha" : "opaque", quality, speed);

    avifRWDataFree(&output);
    avifEncoderDestroy(encoder);
    avifImageDestroy(image);
    free(pixels);
    return 0;
}
