"""
AI Alt Generator Service - Serverless Container

Automatic alt-text generation for images using Qwen Vision API.
Generates WCAG-compliant alt-text, detailed descriptions, and ready-to-use HTML/React code.

Endpoints:
    POST /generate-alt - Generate alt-text for an image
    POST /analyze - Full image analysis (alt-text, objects, scene, colors)
    GET /health - Health check
"""

import base64
import io
import json
import logging
import os
from typing import Optional

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from PIL import Image

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("ai-alt-generator")

# Configuration from environment
QWEN_API_KEY = os.getenv("QWEN_API_KEY", "")
QWEN_BASE_URL = os.getenv("QWEN_BASE_URL", "")  # https://api.scaleway.ai/{project_id}/v1
QWEN_MODEL = os.getenv("QWEN_MODEL", "mistral-small-3.2-24b-instruct-2506")
AUTH_TOKEN = os.getenv("IMAGE_PROCESSOR_TOKEN", "")
MAX_IMAGE_SIZE_MB = int(os.getenv("MAX_IMAGE_SIZE_MB", "10"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "info")
MAX_ALT_TEXT_LENGTH = int(os.getenv("ALT_TEXT_MAX_LENGTH", "250"))

logger.setLevel(getattr(logging, LOG_LEVEL.upper(), logging.INFO))

# WCAG Guidelines for alt-text
# - Short alt-text: max 125 characters (recommended)
# - Long descriptions: can be longer but should be concise
# - Decorative images: empty alt="" (handled separately)

SYSTEM_PROMPT = """You are an accessibility expert specializing in WCAG 2.1 compliance.
Your task is to analyze images and generate high-quality accessibility metadata.

For each image, provide:

1. **alt_text**: A concise, descriptive alt-text (max 125 characters, ideally under 100).
   - Describe the PURPOSE and CONTENT of the image
   - Be specific and meaningful
   - Avoid "image of", "picture of" (redundant)
   - For functional images (buttons, links), describe the ACTION
   - For informative images (charts, graphs), describe the KEY INFORMATION
   - For decorative images, return empty string ""

2. **description**: A detailed description (2-4 sentences) for users who need more context.
   - Include relevant visual details
   - Mention colors, composition, mood if relevant
   - For charts/graphs: describe trends, comparisons, key data points

3. **html**: A complete, accessible HTML <img> tag with:
   - Proper alt attribute
   - Appropriate role if needed
   - aria-label or aria-describedby if applicable
   - Loading="lazy" for performance
   - Semantic class names

4. **react**: A React component with:
   - TypeScript props interface
   - Proper alt text
   - aria-labels
   - Responsive image handling
   - Error handling for failed loads

Respond ONLY in valid JSON format with this exact structure:
{
  "alt_text": "string (max 125 chars)",
  "description": "string (2-4 sentences)",
  "html": "string (<img tag>)",
  "react": "string (React component code)",
  "confidence": "number (0-1)",
  "image_type": "string (photo|illustration|chart|icon|screenshot|other)",
  "decorative": "boolean"
}

Be concise, accurate, and always prioritize accessibility best practices."""


def validate_auth_token(x_auth_token: Optional[str] = None) -> bool:
    """Validate the auth token if configured."""
    if not AUTH_TOKEN:
        return True  # No auth configured, allow all

    if not x_auth_token:
        return False

    token = x_auth_token.replace("Bearer ", "").strip()
    return token == AUTH_TOKEN


def check_image_size(file_content: bytes) -> None:
    """Check if uploaded image is within size limits."""
    max_size_bytes = MAX_IMAGE_SIZE_MB * 1024 * 1024
    if len(file_content) > max_size_bytes:
        raise HTTPException(
            status_code=400, detail=f"Image too large. Maximum size: {MAX_IMAGE_SIZE_MB}MB"
        )


def image_to_base64(image: Image.Image, format: str = "JPEG") -> str:
    """Convert PIL Image to base64 string."""
    buffer = io.BytesIO()
    image.save(buffer, format=format, quality=95)
    buffer.seek(0)
    return base64.b64encode(buffer.read()).decode("utf-8")


async def call_qwen_vision_api(
    image_base64: str, prompt: str = "Generate accessibility metadata for this image."
) -> dict:
    """
    Call Qwen Vision API to analyze image and generate alt-text.

    Args:
        image_base64: Base64-encoded image
        prompt: Custom prompt (uses SYSTEM_PROMPT by default)

    Returns:
        Parsed JSON response from Qwen API

    Raises:
        HTTPException: API call failed
    """
    if not QWEN_API_KEY:
        logger.error("QWEN_API_KEY not configured")
        raise HTTPException(status_code=500, detail="AI service not configured (missing API key)")

    headers = {
        "Authorization": f"Bearer {QWEN_API_KEY}",
        "Content-Type": "application/json",
    }

    payload = {
        "model": QWEN_MODEL,
        "messages": [
            {
                "role": "system",
                "content": SYSTEM_PROMPT,
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"},
                    },
                    {"type": "text", "text": prompt},
                ],
            },
        ],
        "max_tokens": 2000,
        "temperature": 0.3,  # Lower temperature for more consistent output
    }

    logger.info(f"Calling Qwen Vision API ({QWEN_MODEL})...")

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{QWEN_BASE_URL}/chat/completions", headers=headers, json=payload
            )

            if response.status_code != 200:
                logger.error(f"Qwen API error: {response.status_code} - {response.text}")
                raise HTTPException(
                    status_code=500,
                    detail=f"AI service error: {response.status_code}",
                )

            result = response.json()
            content = result["choices"][0]["message"]["content"]

            # Parse JSON response
            try:
                # Handle markdown code blocks if present
                if content.startswith("```"):
                    content = content.split("```")[1]
                    if content.startswith("json"):
                        content = content[4:]
                return json.loads(content.strip())
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse Qwen response: {e}")
                logger.debug(f"Raw response: {content}")
                # Return fallback response
                return {
                    "alt_text": "Image content could not be analyzed",
                    "description": "The AI service returned an invalid response format.",
                    "html": '<img src="" alt="Image content could not be analyzed" loading="lazy" />',
                    "react": "const Image = () => <img src='' alt='Image content could not be analyzed' loading='lazy' />;",
                    "confidence": 0.0,
                    "image_type": "unknown",
                    "decorative": False,
                    "error": "Failed to parse AI response",
                }

    except httpx.TimeoutException:
        logger.error("Qwen API timeout")
        raise HTTPException(status_code=504, detail="AI service timeout")
    except httpx.RequestError as e:
        logger.error(f"Qwen API request error: {e}")
        raise HTTPException(status_code=503, detail="AI service unavailable")


def validate_alt_text(alt_text: str) -> str:
    """Validate and potentially truncate alt-text to meet WCAG guidelines."""
    if not alt_text:
        return ""

    # Trim whitespace
    alt_text = alt_text.strip()

    # Truncate if too long (with ellipsis)
    if len(alt_text) > MAX_ALT_TEXT_LENGTH:
        # Try to cut at word boundary
        truncated = alt_text[: MAX_ALT_TEXT_LENGTH - 3]
        last_space = truncated.rfind(" ")
        if last_space > MAX_ALT_TEXT_LENGTH // 2:
            truncated = truncated[:last_space]
        alt_text = truncated + "..."

    return alt_text


def generate_html_tag(image_url: str, alt_data: dict) -> str:
    """Generate a complete, accessible HTML img tag."""
    alt_text = alt_data.get("alt_text", "")
    description = alt_data.get("description", "")

    # Build img tag with accessibility attributes
    html = f'<img src="{image_url}" alt="{alt_text}"'

    # Add loading="lazy" for performance
    html += ' loading="lazy"'

    # Add long description reference if available
    if description and len(description) > 100:
        desc_id = f"desc-{image_url.split('/')[-1].split('.')[0]}"
        html += f' aria-describedby="{desc_id}"'

    # Add semantic class
    html += ' class="accessible-image"'

    html += " />"

    return html


def generate_react_component(alt_data: dict) -> str:
    """Generate a React component with TypeScript props."""
    alt_text = alt_data.get("alt_text", "")
    image_type = alt_data.get("image_type", "image")

    component_name = f"Accessible{image_type.capitalize().replace('_', '')}"

    return f'''import React, {{ ImgHTMLAttributes }} from 'react';

interface {component_name}Props extends Omit<ImgHTMLAttributes<HTMLImageElement>, 'alt' | 'loading'> {{
  src: string;
  altText?: string;
}}

export const {component_name}: React.FC<{component_name}Props> = ({{
  src,
  altText = "{alt_text[:50]}{"..." if len(alt_text) > 50 else ""}",
  ...props
}}) => {{
  return (
    <img
      src={{src}}
      alt={{altText}}
      loading="lazy"
      decoding="async"
      {{...props}}
    />
  );
}};'''


# FastAPI application
app = FastAPI(
    title="AI Alt Generator",
    description="Automatic alt-text generation using Qwen Vision API",
    version="1.0.0",
)


@app.get("/health")
async def health_check() -> JSONResponse:
    """Health check endpoint."""
    logger.debug("Health check requested")
    return JSONResponse(
        status_code=200,
        content={
            "status": "ok",
            "service": "ai-alt-generator",
            "model": QWEN_MODEL,
            "configured": bool(QWEN_API_KEY),
        },
    )


@app.post("/generate-alt")
async def generate_alt_text(
    file: UploadFile = File(..., description="Image file to analyze"),
    x_auth_token: Optional[str] = Header(None, description="Auth token"),
    include_react: bool = Form(True, description="Include React component in response"),
    include_html: bool = Form(True, description="Include HTML tag in response"),
) -> JSONResponse:
    """
    Generate WCAG-compliant alt-text and accessibility metadata for an image.

    Args:
        file: Uploaded image file
        x_auth_token: Optional auth token for service-to-service auth
        include_react: Include React component code in response
        include_html: Include HTML img tag in response

    Returns:
        JSON with alt_text, description, html, react component, and metadata

    Raises:
        HTTPException: 400 (invalid file/size), 401 (auth failed), 500/503/504 (AI service errors)
    """
    # Validate auth token
    if not validate_auth_token(x_auth_token):
        logger.warning("Auth token validation failed")
        raise HTTPException(status_code=401, detail="Unauthorized")

    # Validate file type
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(
            status_code=400, detail=f"Invalid file type. Expected image, got: {file.content_type}"
        )

    logger.info(f"Alt-text generation request: {file.filename}")

    try:
        # Read image
        file.file.seek(0)
        image_content = await file.read()

        # Check size
        check_image_size(image_content)

        # Open and convert image (ensure consistent format for API)
        image = Image.open(io.BytesIO(image_content))
        if image.mode in ["RGBA", "P"]:
            image = image.convert("RGB")

        logger.info(f"Loaded image: {image.width}x{image.height}, mode: {image.mode}")

        # Convert to base64
        image_base64 = image_to_base64(image)

        # Call Qwen Vision API
        ai_response = await call_qwen_vision_api(image_base64)

        # Validate and process alt-text
        ai_response["alt_text"] = validate_alt_text(ai_response.get("alt_text", ""))

        # Generate HTML tag if requested
        if include_html:
            ai_response["html"] = generate_html_tag("{{image_url}}", ai_response)

        # Generate React component if requested
        if include_react:
            ai_response["react"] = generate_react_component(ai_response)

        # Add metadata
        ai_response["original_size"] = len(image_content)
        ai_response["image_dimensions"] = f"{image.width}x{image.height}"
        ai_response["model"] = QWEN_MODEL

        logger.info(
            f"Alt-text generated: '{ai_response['alt_text'][:50]}...' "
            f"(confidence: {ai_response.get('confidence', 'N/A')})"
        )

        return JSONResponse(content=ai_response)

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Alt generation error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Alt-text generation failed: {str(e)}")


@app.post("/analyze")
async def full_image_analysis(
    file: UploadFile = File(..., description="Image file to analyze"),
    x_auth_token: Optional[str] = Header(None, description="Auth token"),
    custom_prompt: Optional[str] = Form(None, description="Custom analysis prompt"),
) -> JSONResponse:
    """
    Perform comprehensive image analysis including objects, scene, colors, and text.

    Args:
        file: Uploaded image file
        x_auth_token: Optional auth token
        custom_prompt: Optional custom analysis prompt

    Returns:
        Comprehensive analysis including:
        - Alt-text and accessibility metadata
        - Objects detected
        - Scene description
        - Dominant colors
        - Text content (if any)
        - Suggested tags
    """
    if not validate_auth_token(x_auth_token):
        raise HTTPException(status_code=401, detail="Unauthorized")

    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Invalid file type")

    logger.info(f"Full analysis request: {file.filename}")

    try:
        file.file.seek(0)
        image_content = await file.read()
        check_image_size(image_content)

        image = Image.open(io.BytesIO(image_content))
        if image.mode in ["RGBA", "P"]:
            image = image.convert("RGB")

        image_base64 = image_to_base64(image)

        # Default comprehensive analysis prompt
        prompt = (
            custom_prompt
            or """Analyze this image comprehensively and provide:
1. Accessibility metadata (alt_text, description, html, react)
2. List of objects detected
3. Scene type and context
4. Dominant colors (hex codes)
5. Any visible text (OCR)
6. Suggested tags/categories
7. Image type (photo|illustration|chart|icon|screenshot)
8. Confidence score (0-1)

Respond in JSON format."""
        )

        analysis = await call_qwen_vision_api(image_base64, prompt)

        analysis["original_size"] = len(image_content)
        analysis["image_dimensions"] = f"{image.width}x{image.height}"
        analysis["model"] = QWEN_MODEL

        return JSONResponse(content=analysis)

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Analysis error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")


@app.get("/config")
async def get_config() -> JSONResponse:
    """Get service configuration (non-sensitive)."""
    return JSONResponse(
        content={
            "model": QWEN_MODEL,
            "base_url": QWEN_BASE_URL,
            "max_image_size_mb": MAX_IMAGE_SIZE_MB,
            "max_alt_text_length": MAX_ALT_TEXT_LENGTH,
            "auth_enabled": bool(AUTH_TOKEN),
            "configured": bool(QWEN_API_KEY),
        }
    )


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
