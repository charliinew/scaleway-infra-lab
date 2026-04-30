"""
Image Converter Service - Serverless Container

Multi-format image conversion service supporting WebP, AVIF, JPEG, and PNG.
Deployed as a Scaleway Serverless Container with auto-scaling to zero.

Endpoints:
    POST /convert - Convert image to specified format
    GET /health - Health check
"""

import io
import logging
import os
from typing import Optional

import pillow_avif  # noqa: F401 — side-effect import: registers AVIF codec in Pillow
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse, Response
from PIL import Image

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("image-converter")

# Configuration from environment
AUTH_TOKEN = os.getenv("IMAGE_PROCESSOR_TOKEN", "")
LOG_LEVEL = os.getenv("LOG_LEVEL", "info")
MAX_IMAGE_SIZE_MB = int(os.getenv("MAX_IMAGE_SIZE_MB", "10"))

logger.setLevel(getattr(logging, LOG_LEVEL.upper(), logging.INFO))

app = FastAPI(
    title="Image Converter",
    description="Multi-format image conversion service (WebP, AVIF, JPEG, PNG)",
    version="1.0.0",
)

# Supported formats and their MIME types
SUPPORTED_FORMATS = {
    "webp": "image/webp",
    "avif": "image/avif",
    "jpeg": "image/jpeg",
    "jpg": "image/jpeg",
    "png": "image/png",
}

# Format-specific options
FORMAT_OPTIONS = {
    "webp": {"method": 6, "quality": 80},  # Best quality/speed tradeoff
    "avif": {"speed": 6, "quality": 80},  # AVIF encoding speed (0-10)
    "jpeg": {"quality": 80, "optimize": True},
    "png": {"optimize": True, "compress_level": 6},
}


def validate_auth_token(x_auth_token: Optional[str] = None) -> bool:
    """Validate the auth token if configured."""
    if not AUTH_TOKEN:
        return True  # No auth configured, allow all

    if not x_auth_token:
        return False

    # Support both "Bearer token" and just "token" formats
    token = x_auth_token.replace("Bearer ", "").strip()
    return token == AUTH_TOKEN


def check_image_size(file: UploadFile) -> None:
    """Check if uploaded image is within size limits."""
    max_size_bytes = MAX_IMAGE_SIZE_MB * 1024 * 1024

    # Read file to check size
    file.file.seek(0, 2)  # Seek to end
    size = file.file.tell()
    file.file.seek(0)  # Reset to beginning

    if size > max_size_bytes:
        raise HTTPException(
            status_code=400, detail=f"Image too large. Maximum size: {MAX_IMAGE_SIZE_MB}MB"
        )

    logger.debug(f"Image size: {size / 1024:.2f}KB")


def convert_image(
    image: Image.Image, format: str, quality: int, preserve_transparency: bool = True
) -> io.BytesIO:
    """
    Convert a PIL Image to the specified format.

    Args:
        image: PIL Image object
        format: Target format (webp, avif, jpeg, png)
        quality: Quality level (1-100)
        preserve_transparency: Keep alpha channel if present

    Returns:
        BytesIO buffer with converted image
    """
    buffer = io.BytesIO()
    format_lower = format.lower()

    # Get base options for this format
    options = FORMAT_OPTIONS.get(format_lower, {}).copy()
    options["quality"] = quality

    # Handle format-specific requirements
    if format_lower in ["jpeg", "jpg"]:
        # JPEG doesn't support transparency - convert to RGB
        if image.mode in ["RGBA", "LA", "P"]:
            # Create white background
            background = Image.new("RGB", image.size, (255, 255, 255))
            if image.mode == "P":
                image = image.convert("RGBA")
            background.paste(image, mask=image.split()[-1] if image.mode == "RGBA" else None)
            image = background
        elif image.mode != "RGB":
            image = image.convert("RGB")

        options.pop("quality", None)  # JPEG uses 'quality' parameter
        image.save(buffer, format="JPEG", quality=quality, optimize=True)

    elif format_lower == "png":
        # PNG is lossless, quality doesn't apply the same way
        # Use compress_level instead (0-9, higher = better compression)
        if image.mode == "P":
            image = image.convert("RGBA")
        image.save(
            buffer,
            format="PNG",
            optimize=True,
            compress_level=min(9, max(0, quality // 11)),  # Map 0-100 to 0-9
        )

    elif format_lower == "webp":
        # WebP supports transparency
        if image.mode not in ["RGB", "RGBA"]:
            image = image.convert("RGBA")
        image.save(buffer, format="WEBP", method=6, quality=quality, lossless=False, exact=False)

    elif format_lower == "avif":
        # AVIF supports transparency and has better compression than WebP
        if image.mode not in ["RGB", "RGBA"]:
            image = image.convert("RGBA")
        image.save(
            buffer,
            format="AVIF",
            quality=quality,
            speed=6,  # 0=slowest/best, 10=fastest/worst
        )

    else:
        raise ValueError(f"Unsupported format: {format}")

    buffer.seek(0)
    return buffer


@app.get("/health")
async def health_check() -> JSONResponse:
    """Health check endpoint."""
    logger.debug("Health check requested")
    return JSONResponse(status_code=200, content={"status": "ok", "service": "image-converter"})


@app.post("/convert")
async def convert_image_endpoint(
    file: UploadFile = File(..., description="Image file to convert"),
    format: str = Form("webp", description="Target format: webp, avif, jpeg, png"),
    quality: int = Form(80, ge=1, le=100, description="Quality level (1-100)"),
    x_auth_token: Optional[str] = Header(None, description="Auth token"),
) -> Response:
    """
    Convert an image to the specified format.

    Args:
        file: Uploaded image file (PNG, JPEG, WebP, etc.)
        format: Target format (webp, avif, jpeg, png)
        quality: Quality level 1-100 (default: 80)
        x_auth_token: Optional auth token for service-to-service auth

    Returns:
        Converted image file with appropriate Content-Type

    Raises:
        HTTPException: 400 (invalid format/size), 401 (auth failed), 500 (conversion error)
    """
    # Validate auth token
    if not validate_auth_token(x_auth_token):
        logger.warning("Auth token validation failed")
        raise HTTPException(status_code=401, detail="Unauthorized")

    # Validate format
    format_lower = format.lower()
    if format_lower not in SUPPORTED_FORMATS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported format: {format}. Supported: {list(SUPPORTED_FORMATS.keys())}",
        )

    # Validate file type
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(
            status_code=400, detail=f"Invalid file type. Expected image, got: {file.content_type}"
        )

    logger.info(f"Conversion request: {file.filename} -> {format} (quality: {quality})")

    try:
        # Check file size
        check_image_size(file)

        # Read and open image
        file.file.seek(0)
        image_content = await file.read()
        image = Image.open(io.BytesIO(image_content))

        logger.info(
            f"Loaded image: {image.width}x{image.height}, mode: {image.mode}, "
            f"format: {image.format}"
        )

        # Convert image
        buffer = convert_image(image, format_lower, quality)
        converted_bytes = buffer.read()

        logger.info(
            f"Conversion complete: {len(image_content)}B -> {len(converted_bytes)}B "
            f"({100 * len(converted_bytes) / len(image_content):.1f}% of original)"
        )

        # Return converted image
        return Response(
            content=converted_bytes,
            media_type=SUPPORTED_FORMATS[format_lower],
            headers={
                "Content-Disposition": f"attachment; filename=converted.{format_lower}",
                "X-Original-Size": str(len(image_content)),
                "X-Converted-Size": str(len(converted_bytes)),
                "X-Compression-Ratio": f"{100 * len(converted_bytes) / len(image_content):.1f}%",
            },
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Conversion error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Image conversion failed: {str(e)}")


@app.get("/formats")
async def list_formats() -> JSONResponse:
    """List supported formats and their MIME types."""
    return JSONResponse(
        content={
            "supported_formats": list(SUPPORTED_FORMATS.keys()),
            "mime_types": SUPPORTED_FORMATS,
            "format_options": FORMAT_OPTIONS,
        }
    )


@app.post("/optimize")
async def optimize_image(
    file: UploadFile = File(...), x_auth_token: Optional[str] = Header(None)
) -> Response:
    """
    Optimize an image without changing format.
    Automatically selects the best format based on input.
    """
    if not validate_auth_token(x_auth_token):
        raise HTTPException(status_code=401, detail="Unauthorized")

    try:
        file.file.seek(0)
        image_content = await file.read()
        image = Image.open(io.BytesIO(image_content))

        # Determine format from original
        original_format = image.format.lower() if image.format else "webp"
        format_map = {"PNG": "webp", "JPEG": "jpeg", "JPG": "jpeg", "WEBP": "webp", "AVIF": "avif"}
        target_format = format_map.get(original_format, "webp")

        logger.info(f"Optimizing {original_format} -> {target_format}")

        # Convert with high quality (90)
        buffer = convert_image(image, target_format, quality=90)
        converted_bytes = buffer.read()

        return Response(
            content=converted_bytes,
            media_type=SUPPORTED_FORMATS[target_format],
            headers={
                "X-Original-Format": original_format,
                "X-Optimized-Format": target_format,
                "X-Original-Size": str(len(image_content)),
                "X-Optimized-Size": str(len(converted_bytes)),
                "X-Savings": f"{100 - 100 * len(converted_bytes) / len(image_content):.1f}%",
            },
        )

    except Exception as e:
        logger.error(f"Optimization error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Optimization failed: {str(e)}")


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
