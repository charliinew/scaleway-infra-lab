-- Migration: 001_add_alt_texts.sql
-- Description: Add image_alt_texts table for AI-generated accessibility metadata
-- Created: 2024
-- Phase: 2 - API Migration to Kubernetes

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create image_alt_texts table
CREATE TABLE IF NOT EXISTS image_alt_texts (
    -- Primary key
    id VARCHAR(255) PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Foreign key to images table
    image_id VARCHAR(255) NOT NULL UNIQUE REFERENCES images(id) ON DELETE CASCADE,

    -- Alt-text (WCAG: max 125 characters recommended, we allow 255 for flexibility)
    alt_text VARCHAR(255) NOT NULL DEFAULT '',

    -- Detailed description for users who need more context
    description TEXT,

    -- Complete HTML img tag with accessibility attributes
    html_tag TEXT,

    -- React component code for TypeScript/React projects
    react_component TEXT,

    -- Image classification (photo, illustration, chart, icon, screenshot, etc.)
    image_type VARCHAR(50) DEFAULT 'unknown',

    -- Whether image is decorative (should have empty alt="")
    decorative BOOLEAN DEFAULT FALSE,

    -- AI confidence score (0.0 to 1.0)
    confidence DECIMAL(3,2) CHECK (confidence >= 0.0 AND confidence <= 1.0),

    -- Timestamps
    generated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- Metadata
    created_by VARCHAR(50) DEFAULT 'ai-alt-generator',
    model_version VARCHAR(50) DEFAULT 'qwen-vl-max'
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_image_alt_texts_image_id
    ON image_alt_texts(image_id);

CREATE INDEX IF NOT EXISTS idx_image_alt_texts_image_type
    ON image_alt_texts(image_type);

CREATE INDEX IF NOT EXISTS idx_image_alt_texts_decorative
    ON image_alt_texts(decorative);

CREATE INDEX IF NOT EXISTS idx_image_alt_texts_generated_at
    ON image_alt_texts(generated_at DESC);

-- Create index on confidence for filtering low-confidence results
CREATE INDEX IF NOT EXISTS idx_image_alt_texts_confidence
    ON image_alt_texts(confidence) WHERE confidence < 0.5;

-- Add trigger to auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_image_alt_texts_updated_at
    BEFORE UPDATE ON image_alt_texts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Add comment for documentation
COMMENT ON TABLE image_alt_texts IS 'AI-generated accessibility metadata for images (alt-text, descriptions, HTML/React code)';

COMMENT ON COLUMN image_alt_texts.alt_text IS 'WCAG-compliant alt-text (max 125 chars recommended, 255 max)';
COMMENT ON COLUMN image_alt_texts.description IS 'Detailed description for users needing more context (2-4 sentences)';
COMMENT ON COLUMN image_alt_texts.html_tag IS 'Complete accessible HTML img tag with aria attributes';
COMMENT ON COLUMN image_alt_texts.react_component IS 'TypeScript React component with proper accessibility';
COMMENT ON COLUMN image_alt_texts.image_type IS 'Classification: photo, illustration, chart, icon, screenshot, etc.';
COMMENT ON COLUMN image_alt_texts.decorative IS 'True if image is decorative (empty alt="") per WCAG';
COMMENT ON COLUMN image_alt_texts.confidence IS 'AI confidence score 0.0-1.0 for generated metadata';

-- Grant appropriate permissions (adjust based on your DB user)
-- GRANT SELECT, INSERT, UPDATE, DELETE ON image_alt_texts TO onboarding;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO onboarding;

-- Rollback command (for documentation):
-- DROP TRIGGER IF EXISTS update_image_alt_texts_updated_at ON image_alt_texts;
-- DROP FUNCTION IF EXISTS update_updated_at_column();
-- DROP INDEX IF EXISTS idx_image_alt_texts_confidence;
-- DROP INDEX IF EXISTS idx_image_alt_texts_generated_at;
-- DROP INDEX IF EXISTS idx_image_alt_texts_decorative;
-- DROP INDEX IF EXISTS idx_image_alt_texts_image_type;
-- DROP INDEX IF EXISTS idx_image_alt_texts_image_id;
-- DROP TABLE IF EXISTS image_alt_texts;
