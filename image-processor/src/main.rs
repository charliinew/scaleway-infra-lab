use actix_web::{get, post, web, App, HttpResponse, HttpServer};
use image::codecs::jpeg::JpegEncoder;
use image::load_from_memory;
use log::{debug, info};
use std::io::Cursor;

#[get("/health")]
async fn health_check() -> HttpResponse {
    debug!("Health");

    HttpResponse::Ok().body("OK")
}

#[post("/process")]
async fn process_image(payload: web::Bytes) -> HttpResponse {
    debug!(
        "Received image processing request with payload size: {} bytes",
        payload.len()
    );

    match load_from_memory(&payload) {
        Ok(img) => {
            debug!(
                "Successfully loaded image from memory. Dimensions: {}x{}",
                img.width(),
                img.height()
            );

            let mut buffer = Cursor::new(Vec::new());
            let mut encoder = JpegEncoder::new_with_quality(&mut buffer, 80);
            match encoder.encode_image(&img) {
                Ok(()) => HttpResponse::Ok().body(buffer.into_inner()),
                Err(e) => {
                    debug!("Image processing error: {}", e);
                    HttpResponse::InternalServerError().body("Image processing error")
                }
            }
        }
        Err(e) => {
            debug!("Invalid image data: {}", e);
            HttpResponse::BadRequest().body("Invalid image data")
        }
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    let port = std::env::var("PORT").unwrap_or_else(|_| "9090".to_string());

    info!("Starting image processing server on port {}", port);
    HttpServer::new(|| App::new().service(process_image).service(health_check))
        .bind(format!("0.0.0.0:{}", port))?
        .run()
        .await
}
