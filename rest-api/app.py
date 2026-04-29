import base64
import json
import logging
import os
import urllib.request
import uuid
from datetime import datetime

import aiohttp
from boto3.session import Session
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import Column, DateTime, ForeignKey, String, Text, create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship, sessionmaker

logger = logging.getLogger("uvicorn.error")

ENDPOINT_URL = "s3.fr-par.scw.cloud"


def fetch_secret(secret_name: str, secret_key: str, project_id: str, region: str = "fr-par") -> str:
    """Fetch a secret version from Scaleway Secret Manager."""
    # List secrets filtered by name to get the secret ID
    list_url = (
        f"https://api.scaleway.com/secret-manager/v1beta1/regions/{region}"
        f"/secrets?project_id={project_id}&name={secret_name}"
    )
    req = urllib.request.Request(list_url, headers={"X-Auth-Token": secret_key})
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read())
    secrets = data.get("secrets", [])
    if not secrets:
        raise ValueError(f"Secret '{secret_name}' not found in project {project_id}")
    secret_id = secrets[0]["id"]

    # Access the latest version by secret ID
    access_url = (
        f"https://api.scaleway.com/secret-manager/v1beta1/regions/{region}"
        f"/secrets/{secret_id}/versions/latest/access"
    )
    req = urllib.request.Request(access_url, headers={"X-Auth-Token": secret_key})
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read())
        return base64.b64decode(data["data"]).decode()


def resolve(env_var: str, secret_name: str | None, secret_key: str, project_id: str) -> str | None:
    """Return env var value if set, otherwise fetch from Secret Manager."""
    value = os.getenv(env_var)
    if value:
        return value
    if not secret_name:
        return None
    try:
        value = fetch_secret(secret_name, secret_key, project_id)
        logger.info(f"Loaded {env_var} from Secret Manager ({secret_name})")
        return value
    except Exception as e:
        logger.warning(f"Could not fetch secret {secret_name}: {e}")
        return None


ACCESS_KEY = os.getenv("ONBOARDING_ACCESS_KEY")
if not ACCESS_KEY:
    raise ValueError("ONBOARDING_ACCESS_KEY environment variable is not set.")

SECRET_KEY = os.getenv("ONBOARDING_SECRET_KEY")
if not SECRET_KEY:
    raise ValueError("ONBOARDING_SECRET_KEY environment variable is not set.")

PROJECT_ID = os.getenv("ONBOARDING_PROJECT_ID", "")

DATABASE_URL = resolve("ONBOARDING_DATABASE_URL", "onboarding-database-url", SECRET_KEY, PROJECT_ID)
if not DATABASE_URL:
    raise ValueError(
        "ONBOARDING_DATABASE_URL is not set and could not be fetched from Secret Manager."
    )

BUCKET_NAME = resolve("ONBOARDING_BUCKET_NAME", "onboarding-bucket-name", SECRET_KEY, PROJECT_ID)
if not BUCKET_NAME:
    logger.warning(
        "ONBOARDING_BUCKET_NAME is not set and could not be fetched from Secret Manager. Images will not be stored."
    )

IMAGE_PROCESSOR_URL = os.getenv("ONBOARDING_IMAGE_PROCESSOR_URL")
if not IMAGE_PROCESSOR_URL:
    logger.warning(
        "ONBOARDING_IMAGE_PROCESSOR_URL not set. Image conversion unavailable until configmap is updated post-deploy."
    )

IMAGE_PROCESSOR_TOKEN = os.getenv("ONBOARDING_IMAGE_PROCESSOR_TOKEN")
if not IMAGE_PROCESSOR_TOKEN:
    logger.info("ONBOARDING_IMAGE_PROCESSOR_TOKEN environment variable is not set.")

# New Serverless service URLs
IMAGE_CONVERTER_URL = os.getenv("ONBOARDING_IMAGE_CONVERTER_URL", IMAGE_PROCESSOR_URL)
AI_GENERATOR_URL = os.getenv("ONBOARDING_AI_GENERATOR_URL")
if AI_GENERATOR_URL:
    logger.info(f"AI Alt Generator enabled at {AI_GENERATOR_URL}")
else:
    logger.warning("ONBOARDING_AI_GENERATOR_URL not set. AI alt-text generation disabled.")

app = FastAPI(
    title="Image Converter API",
    description="PNG to WebP/AVIF/JPEG/PNG conversion with AI alt-text generation",
    version="2.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

import os as _os
_web_dir = _os.path.join(_os.path.dirname(__file__), "web")
if _os.path.isdir(_web_dir):
    app.mount("/static", StaticFiles(directory=_web_dir), name="static")

    @app.get("/")
    async def serve_index():
        return FileResponse(_os.path.join(_web_dir, "index.html"))

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


class ImageRecord(Base):
    __tablename__ = "images"
    id = Column(String, primary_key=True, index=True)
    url = Column(String, unique=True, index=True)
    format = Column(String, default="jpeg")  # webp, avif, jpeg, png
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationship to alt-text
    alt_text = relationship(
        "ImageAltText", back_populates="image", uselist=False, cascade="all, delete-orphan"
    )


class ImageAltText(Base):
    __tablename__ = "image_alt_texts"
    id = Column(String, primary_key=True, index=True)
    image_id = Column(String, ForeignKey("images.id"), unique=True, index=True)
    alt_text = Column(String(255))  # WCAG: max 125 chars recommended
    description = Column(Text)  # Detailed description
    html_tag = Column(Text)  # Complete HTML img tag
    react_component = Column(Text)  # React component code
    image_type = Column(String)  # photo, illustration, chart, icon, etc.
    decorative = Column(String, default="false")  # "true" or "false"
    confidence = Column(String)  # AI confidence score
    generated_at = Column(DateTime, default=datetime.utcnow)

    image = relationship("ImageRecord", back_populates="alt_text")


# Create all tables (including new image_alt_texts)
Base.metadata.create_all(bind=engine)


async def save_image_record(url: str, format: str = "jpeg") -> dict:
    """Save image record to database with format information."""
    db = SessionLocal()
    image_record = ImageRecord(id=str(uuid.uuid4()), url=url, format=format)
    result = {"id": image_record.id, "url": image_record.url, "format": format}
    db.add(image_record)
    db.commit()
    db.refresh(image_record)  # Refresh to get the generated ID
    db.close()
    return result


async def save_alt_text_record(image_id: str, alt_data: dict) -> dict:
    """Save AI-generated alt-text to database."""
    db = SessionLocal()
    alt_record = ImageAltText(
        id=str(uuid.uuid4()),
        image_id=image_id,
        alt_text=alt_data.get("alt_text", ""),
        description=alt_data.get("description", ""),
        html_tag=alt_data.get("html", ""),
        react_component=alt_data.get("react", ""),
        image_type=alt_data.get("image_type", "unknown"),
        decorative=str(alt_data.get("decorative", False)).lower(),
        confidence=str(alt_data.get("confidence", 0.0)),
    )
    db.add(alt_record)
    db.commit()
    db.refresh(alt_record)
    db.close()
    return {
        "id": alt_record.id,
        "alt_text": alt_record.alt_text,
        "description": alt_record.description,
        "html_tag": alt_record.html_tag,
        "react_component": alt_record.react_component,
        "image_type": alt_record.image_type,
        "confidence": alt_record.confidence,
    }


@app.get("/health")
async def health_check():
    """Health check with service status."""
    return {
        "status": "ok",
        "services": {
            "converter": IMAGE_CONVERTER_URL,
            "ai_generator": AI_GENERATOR_URL or "not configured",
            "database": "connected",
            "storage": BUCKET_NAME or "not configured",
        },
    }


@app.get("/formats")
async def list_formats():
    """List supported image formats."""
    return {
        "supported_formats": ["webp", "avif", "jpeg", "png"],
        "default_format": "webp",
        "quality_range": {"min": 1, "max": 100, "default": 80},
    }


@app.get("/images/{image_id}")
async def get_image(image_id: str):
    """Get image record by ID with optional alt-text."""
    db = SessionLocal()
    image_record = db.query(ImageRecord).filter(ImageRecord.id == image_id).first()
    if not image_record:
        db.close()
        raise HTTPException(status_code=404, detail="Image not found")

    result = {
        "id": image_record.id,
        "url": image_record.url,
        "format": image_record.format,
        "created_at": image_record.created_at.isoformat() if image_record.created_at else None,
    }

    if image_record.alt_text:
        result["alt_text"] = {
            "id": image_record.alt_text.id,
            "alt_text": image_record.alt_text.alt_text,
            "description": image_record.alt_text.description,
            "html_tag": image_record.alt_text.html_tag,
            "image_type": image_record.alt_text.image_type,
            "confidence": image_record.alt_text.confidence,
        }

    db.close()
    return result


@app.get("/images")
async def list_images(limit: int = 100, offset: int = 0):
    """List images with pagination."""
    db = SessionLocal()
    images = (
        db.query(ImageRecord)
        .order_by(ImageRecord.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )
    result = []
    for img in images:
        img_data = {
            "id": img.id,
            "url": img.url,
            "format": img.format,
            "created_at": img.created_at.isoformat() if img.created_at else None,
            "has_alt_text": bool(img.alt_text),
        }
        result.append(img_data)
    db.close()
    return {"images": result, "limit": limit, "offset": offset, "total": len(result)}


@app.post("/upload")
async def upload_image(
    file: UploadFile = File(...),
    format: str = Form("webp", description="Target format: webp, avif, jpeg, png"),
    quality: int = Form(80, ge=1, le=100, description="Quality level 1-100"),
    generate_alt: bool = Form(False, description="Generate AI alt-text"),
):
    """
    Upload and convert image with optional AI alt-text generation.

    Args:
        file: PNG image file
        format: Target format (webp, avif, jpeg, png)
        quality: Quality level 1-100
        generate_alt: Whether to generate AI alt-text

    Returns:
        Image record with URL, format, and optional alt-text
    """
    logger.debug(f"Received image upload request (format={format}, alt={generate_alt})")

    # Validate file type
    if file.content_type != "image/png":
        raise HTTPException(status_code=400, detail="File must be a PNG image.")

    if not IMAGE_CONVERTER_URL:
        raise HTTPException(
            status_code=503,
            detail="Image converter not configured yet. Retry in a moment — deployment is still in progress.",
        )

    # Validate format
    supported_formats = ["webp", "avif", "jpeg", "png"]
    format_lower = format.lower()
    if format_lower not in supported_formats:
        raise HTTPException(
            status_code=400, detail=f"Unsupported format: {format}. Supported: {supported_formats}"
        )

    # Read original file
    original_bytes = await file.read()

    # Send file to image converter (Serverless)
    logger.debug(f"Will send image to converter {IMAGE_CONVERTER_URL}/convert")
    async with aiohttp.ClientSession() as session:
        headers = {}
        if IMAGE_PROCESSOR_TOKEN:
            headers["X-Auth-Token"] = IMAGE_PROCESSOR_TOKEN

        # Prepare multipart form for converter
        converter_form = aiohttp.FormData()
        converter_form.add_field(
            "file", original_bytes, filename=file.filename, content_type=file.content_type
        )
        converter_form.add_field("format", format_lower)
        converter_form.add_field("quality", str(quality))

        async with session.post(
            f"{IMAGE_CONVERTER_URL}/convert", headers=headers, data=converter_form
        ) as response:
            if response.status != 200:
                error_text = await response.text()
                logger.error(f"Converter error: {response.status} - {error_text}")
                raise HTTPException(
                    status_code=500, detail=f"Image conversion failed: {error_text}"
                )

            # Get conversion metrics from headers
            original_size = response.headers.get("X-Original-Size", "0")
            converted_size = response.headers.get("X-Converted-Size", "0")
            compression_ratio = response.headers.get("X-Compression-Ratio", "100%")

            logger.info(
                f"Conversion complete: {original_size}B -> {converted_size}B ({compression_ratio})"
            )
            processed_image = await response.read()

    # Save processed image to Scaleway Object Storage
    image_id = str(uuid.uuid4())
    extension = "jpg" if format_lower == "jpeg" else format_lower
    filename = f"{image_id}.{extension}"
    content_type = f"image/{format_lower}"
    object_storage_url = f"https://{BUCKET_NAME}.{ENDPOINT_URL}/{filename}"

    if BUCKET_NAME:
        logger.debug(f"Will upload image {filename} to S3 bucket {BUCKET_NAME}")

        s3_session = Session()
        s3_client = s3_session.client(
            "s3",
            endpoint_url=f"https://{ENDPOINT_URL}",
            region_name="fr-par",
            aws_access_key_id=ACCESS_KEY,
            aws_secret_access_key=SECRET_KEY,
        )

        try:
            s3_client.put_object(
                Bucket=BUCKET_NAME,
                Key=filename,
                Body=processed_image,
                ContentType=content_type,
                ACL="public-read",
            )
        except s3_client.exceptions.NoSuchBucket:
            raise HTTPException(
                status_code=503,
                detail=f"Storage bucket '{BUCKET_NAME}' is not available yet. The bucket may still be provisioning — retry in a moment.",
            )
        except Exception as e:
            logger.error(f"S3 upload failed: {e}")
            raise HTTPException(status_code=500, detail=f"Storage upload failed: {str(e)}")

    # Store image URL in database
    logger.debug("Will save image URL in database")
    record = await save_image_record(object_storage_url, format=format_lower)
    result = {"id": record["id"], "url": record["url"], "format": format_lower}

    # Add compression metrics
    if original_size and converted_size:
        result["original_size"] = int(original_size)
        result["converted_size"] = int(converted_size)
        result["compression_ratio"] = compression_ratio

    # Generate AI alt-text if requested
    if generate_alt and AI_GENERATOR_URL:
        logger.debug("Will generate AI alt-text")
        try:
            alt_form = aiohttp.FormData()
            alt_form.add_field(
                "file", processed_image, filename=filename, content_type=content_type
            )

            async with aiohttp.ClientSession() as ai_session:
                async with ai_session.post(
                    f"{AI_GENERATOR_URL}/generate-alt", headers=headers, data=alt_form
                ) as alt_response:
                    if alt_response.status == 200:
                        alt_data = await alt_response.json()
                        alt_record = await save_alt_text_record(record["id"], alt_data)
                        result["alt_text"] = alt_record
                        logger.info(f"Alt-text generated: {alt_data.get('alt_text', '')[:50]}...")
                    else:
                        logger.warning(f"AI alt generation failed: {alt_response.status}")
        except Exception as e:
            logger.error(f"Alt-text generation error: {e}")
            # Don't fail the whole request, just log the error

    return result
