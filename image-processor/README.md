### Local test

```bash
curl -X POST \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/path/to/image.png \
  http://localhost:9090/process \
  -o processed_image.jpg
```
