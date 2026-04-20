import base64
import json
import logging
import os
import urllib.request
import uuid

import aiohttp
from boto3.session import Session
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import Column, String, create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker

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
    raise ValueError("ONBOARDING_DATABASE_URL is not set and could not be fetched from Secret Manager.")

BUCKET_NAME = resolve("ONBOARDING_BUCKET_NAME", "onboarding-bucket-name", SECRET_KEY, PROJECT_ID)
if not BUCKET_NAME:
    logger.warning("ONBOARDING_BUCKET_NAME is not set and could not be fetched from Secret Manager. Images will not be stored.")

IMAGE_PROCESSOR_URL = os.getenv("ONBOARDING_IMAGE_PROCESSOR_URL")
if not IMAGE_PROCESSOR_URL:
    raise ValueError("ONBOARDING_IMAGE_PROCESSOR_URL environment variable is not set.")

IMAGE_PROCESSOR_TOKEN = os.getenv("ONBOARDING_IMAGE_PROCESSOR_TOKEN")
if not IMAGE_PROCESSOR_TOKEN:
    logger.info("ONBOARDING_IMAGE_PROCESSOR_TOKEN environment variable is not set.")

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


class ImageRecord(Base):
    __tablename__ = "images"
    id = Column(String, primary_key=True, index=True)
    url = Column(String, unique=True, index=True)


Base.metadata.create_all(bind=engine)


async def save_image_record(url: str):
    db = SessionLocal()
    image_record = ImageRecord(id=str(uuid.uuid4()), url=url)
    result = {"id": image_record.id, "url": image_record.url}
    db.add(image_record)
    db.commit()
    db.close()
    return result


@app.get("/health")
async def health_check():
    return {"status": "ok"}


@app.post("/upload")
async def upload_image(file: UploadFile = File(...)):
    logger.debug("Received image upload request")

    if file.content_type != "image/png":
        raise HTTPException(status_code=400, detail="File must be a PNG image.")

    # Send file to image processor
    logger.debug(f"Will send image to image processor {IMAGE_PROCESSOR_URL}/process")
    async with aiohttp.ClientSession() as session:

        headers = {}
        if IMAGE_PROCESSOR_TOKEN:
            headers["X-Auth-Token"] = IMAGE_PROCESSOR_TOKEN

        async with session.post(
            f"{IMAGE_PROCESSOR_URL}/process", headers=headers, data=await file.read()
        ) as response:
            if response.status != 200:
                raise HTTPException(status_code=500, detail="Image processing failed.")
            processed_image = await response.read()

    # Save processed image to Scaleway Object Storage
    image_id = str(uuid.uuid4())
    jpeg_filename = f"{image_id}.jpeg"
    object_storage_url = f"https://{BUCKET_NAME}.{ENDPOINT_URL}/{jpeg_filename}"

    if BUCKET_NAME:
        logger.debug(f"Will upload image {jpeg_filename} to S3 bucket {BUCKET_NAME}")

        session = Session()
        s3_client = session.client(
            "s3",
            endpoint_url=f"https://{ENDPOINT_URL}",
            region_name="fr-par",
            aws_access_key_id=ACCESS_KEY,
            aws_secret_access_key=SECRET_KEY,
        )

        s3_client.put_object(
            Bucket=BUCKET_NAME,
            Key=jpeg_filename,
            Body=processed_image,
            ContentType="image/jpeg",
        )

    # Store image URL in database
    logger.debug("Will save image URL in database")
    record = await save_image_record(object_storage_url)
    return record
