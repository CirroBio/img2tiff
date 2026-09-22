## img2tiff

Convert whole-slide and microscopy images to pyramidal OME-TIFF with QuPath,
in headless mode.

One Nextflow task per image, so a cohort converts in parallel and each image is
published as it finishes.


## Nextflow Workflow

Parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `input_folder` | — | Folder holding the images to convert. Searched recursively. |
| `image_format` | `vsi` | File suffix to convert. |
| `output` | — | Folder where results are published. |
| `compression` | `JPEG` | Any QuPath `CompressionType`: `JPEG`, `ZLIB`, `LZW`, `J2K`, `J2K_LOSSY`, `UNCOMPRESSED`, `DEFAULT`. |
| `pyramid_scale` | `2` | Downsample factor between pyramid levels. |
| `tile_size` | `1024` | Tile height and width. |
| `skip_existing` | `false` | Skip images whose OME-TIFF is already in `output`. |
| `cpus` | `4` | CPUs per image. |
| `memory_gb` | `16` | Memory per image; doubled on each retry. |
| `max_retries` | `2` | Retries for out-of-memory and reclaimed hosts. |
| `container` | `public.ecr.aws/cirrobio/qupath:0046339` | Image QuPath runs in. |

Run it standalone with:

```bash
nextflow run CirroBio/img2tiff -profile docker \
    --input_folder slides/ --image_format svs --output converted/
```

### Behaviour

Every file under `input_folder` with the `image_format` suffix is converted, at any
depth. Formats which pack several images into one file — `vsi`, `scn`, `dcm`, `dicom`,
`nd2`, `lif`, `czi` — are passed to `img2tiff_headless.groovy`, which writes every
series as a separate OME-TIFF. Everything else goes through QuPath's `convert-ome`
CLI.

Each image is one task. On a cluster or in the cloud they run in parallel, each
staging only its own image, and `publishDir` writes each result as it completes — so a
run which is interrupted keeps everything converted up to that point, and `-resume`
picks up the rest.

Alongside the images the workflow writes `<image>.log.txt` per image and one
`conversion_timings.tsv` for the run, giving seconds and input/output bytes per image.
That is what to measure a large cohort against before committing to it.

### Choosing a compression

`JPEG` is the default. Images from brightfield slide scanners — SVS in particular —
already hold lossy JPEG tiles written by the scanner, so a lossless codec re-encodes
them and inflates the output substantially without recovering any fidelity that was
lost before the file was written. Use a lossless option — `ZLIB`, `LZW`, `J2K`,
`UNCOMPRESSED` — for images which were never lossily compressed, such as fluorescence
acquisitions.

Two of them are conditional on the image: `JPEG` needs an RGB or 8-bit image, and
`J2K`/`J2K_LOSSY` need 8- or 16-bit. QuPath refuses the conversion rather than writing
something wrong. `DEFAULT` lets it choose from the image itself.

### Failures

QuPath returns 0 even when it cannot read an image: it logs the exception and carries
on. Success is therefore asserted on the output actually written, never on the exit
status. An image which produces nothing fails its own task and names itself in the
error; the rest of the cohort is unaffected, and what had already converted stays
published.

Out-of-memory and reclaimed spot hosts are retried with doubled memory. Anything else
is a real conversion failure and is left loud.


## Standalone Script: img2tiff_headless.groovy

Arguments:
  - param1: input image path
  - param2: output folder
  - param3: compression (`JPEG` or `ZLIB`, optional)
  - param4: file extension (optional, defaults to `vsi`)

Every series in the image is written out, up to a cap of ten.

The H&E images we work with have at least four series:

0. Slide Label
1. Medium resolution overview
2. Full resolution (e.g. 40X brightfield)

A full resolution image takes around 10 minutes to convert on 2 cores of an M1 Apple
Silicon MacBook Pro.
