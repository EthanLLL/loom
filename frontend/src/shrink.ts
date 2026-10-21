/**
 * Shrink a picked image before it is uploaded.
 *
 * The models never see more than about 2000 px on the long edge — Claude Code
 * scales every image it reads down to that, and Bedrock caps a whole request,
 * history and all, at about 32 MB — so a 4032×3024 photo from a phone is
 * mostly bytes nobody will look at, and slow to send over a phone's uplink.
 * Only the size changes: PNG stays PNG, JPEG stays JPEG at a high quality, and
 * a photo keeps its EXIF (time, place, camera), which the model can use.
 *
 * Anything that cannot be decoded here, is already small enough, or would not
 * come out smaller goes up as it is. GIF and SVG are never touched: one may
 * move, the other has no pixels to scale.
 */
export const MAX_EDGE = 2000
const QUALITY = 0.92

export async function shrinkImage(file: File): Promise<File> {
  if (!file.type.startsWith("image/") || /gif|svg/.test(file.type)) return file
  try {
    return (await shrink(file)) ?? file
  } catch {
    return file
  }
}

async function shrink(file: File): Promise<File | null> {
  // Upright: the EXIF orientation is applied while decoding.
  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" })
  const { width, height } = bitmap
  const scale = MAX_EDGE / Math.max(width, height)
  if (scale >= 1) {
    bitmap.close()
    return null
  }
  const w = Math.round(width * scale)
  const h = Math.round(height * scale)
  const canvas = document.createElement("canvas")
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext("2d")
  if (!ctx) return null
  ctx.imageSmoothingQuality = "high"
  ctx.drawImage(bitmap, 0, 0, w, h)
  bitmap.close()

  // HEIC and the like only decode in some browsers and are read by no model,
  // so they come out as JPEG.
  const type = ["image/png", "image/webp"].includes(file.type) ? file.type : "image/jpeg"
  const blob = await new Promise<Blob | null>((done) => canvas.toBlob(done, type, QUALITY))
  // A browser that cannot encode WebP hands back a PNG instead.
  if (!blob || blob.type !== type) return null

  let out: Blob = blob
  if (type === "image/jpeg" && file.type === "image/jpeg") {
    let exif: Uint8Array<ArrayBuffer> | null = null
    try {
      exif = exifSegment(new Uint8Array(await file.arrayBuffer()), w, h)
    } catch {
      // A malformed EXIF loses the metadata, not the smaller upload.
    }
    if (exif) out = withExif(new Uint8Array(await blob.arrayBuffer()), exif)
  }
  if (out.size >= file.size) return null
  const name = type === file.type ? file.name : file.name.replace(/\.[^.]*$/, "") + ".jpg"
  return new File([out], name, { type, lastModified: file.lastModified })
}

/**
 * The original's EXIF segment (APP1), patched for the new pixels: the
 * orientation is now 1, as the pixels were turned upright; the stored size is
 * the new one; and the thumbnail is dropped, as it is still the unturned one.
 * Patched in place, so every offset inside — the maker note's too — still holds.
 */
function exifSegment(jpeg: Uint8Array, width: number, height: number): Uint8Array<ArrayBuffer> | null {
  let at = 2
  while (at + 4 <= jpeg.length && jpeg[0] === 0xff && jpeg[1] === 0xd8) {
    if (jpeg[at] !== 0xff) return null
    const marker = jpeg[at + 1]
    // Start of scan: the headers are over.
    if (marker === 0xda) return null
    const length = (jpeg[at + 2] << 8) | jpeg[at + 3]
    if (marker === 0xe1 && ascii(jpeg, at + 4, 6) === "Exif\0\0") {
      const segment = jpeg.slice(at, at + 2 + length)
      return patchTiff(segment, 10, width, height) ? segment : null
    }
    at += 2 + length
  }
  return null
}

function patchTiff(seg: Uint8Array, base: number, width: number, height: number): boolean {
  const view = new DataView(seg.buffer, seg.byteOffset + base, seg.length - base)
  const order = ascii(seg, base, 2)
  if (order !== "II" && order !== "MM") return false
  const le = order === "II"
  const u16 = (o: number) => view.getUint16(o, le)
  const u32 = (o: number) => view.getUint32(o, le)

  // Calls `visit` with each entry's tag, type and value offset; returns where
  // the next IFD's offset is kept.
  const walk = (ifd: number, visit: (tag: number, type: number, value: number) => void) => {
    const count = u16(ifd)
    for (let i = 0; i < count; i++) {
      const entry = ifd + 2 + i * 12
      visit(u16(entry), u16(entry + 2), entry + 8)
    }
    return ifd + 2 + count * 12
  }
  const set = (type: number, value: number, n: number) => {
    if (type === 3) view.setUint16(value, n, le)
    else if (type === 4) view.setUint32(value, n, le)
  }

  const ifd0 = u32(4)
  let exifIfd = 0
  const next = walk(ifd0, (tag, type, value) => {
    if (tag === 0x0112) set(type, value, 1) // Orientation
    if (tag === 0x8769) exifIfd = u32(value)
  })
  view.setUint32(next, 0, le) // no IFD1: no thumbnail
  if (exifIfd) {
    walk(exifIfd, (tag, type, value) => {
      if (tag === 0xa002) set(type, value, width) // PixelXDimension
      if (tag === 0xa003) set(type, value, height) // PixelYDimension
    })
  }
  return true
}

/** `jpeg` with `exif` put in after its JFIF header, where readers look. */
function withExif(jpeg: Uint8Array, exif: Uint8Array<ArrayBuffer>): Blob {
  let at = 2
  if (jpeg[2] === 0xff && jpeg[3] === 0xe0) at = 4 + ((jpeg[4] << 8) | jpeg[5])
  return new Blob([jpeg.slice(0, at), exif, jpeg.slice(at)], { type: "image/jpeg" })
}

function ascii(bytes: Uint8Array, at: number, n: number): string {
  return String.fromCharCode(...bytes.slice(at, at + n))
}
