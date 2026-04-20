const API = 'http://localhost:8080'

// ── Health check ──────────────────────────────────────
async function checkHealth() {
  const dot  = document.getElementById('dot')
  const text = document.getElementById('statusText')
  try {
    const r = await fetch(`${API}/health`)
    if (r.ok) {
      dot.className    = 'dot online'
      text.textContent = 'API online'
    } else throw new Error()
  } catch {
    dot.className    = 'dot offline'
    text.textContent = 'API offline'
  }
}
checkHealth()

// ── Elements ──────────────────────────────────────────
const dropZone     = document.getElementById('dropZone')
const fileInput    = document.getElementById('fileInput')
const previewCard  = document.getElementById('previewCard')
const previewThumb = document.getElementById('previewThumb')
const previewName  = document.getElementById('previewName')
const previewSize  = document.getElementById('previewSize')
const btnClear     = document.getElementById('btnClear')
const btnConvert   = document.getElementById('btnConvert')
const progressWrap = document.getElementById('progressWrap')
const progressFill = document.getElementById('progressFill')
const progressLabel= document.getElementById('progressLabel')
const progressPct  = document.getElementById('progressPct')
const errorMsg     = document.getElementById('errorMsg')
const resultCard   = document.getElementById('resultCard')
const resultImg    = document.getElementById('resultImg')
const resultUrl    = document.getElementById('resultUrl')
const btnCopy      = document.getElementById('btnCopy')

let selectedFile = null

// ── Drag & drop ───────────────────────────────────────
;['dragenter', 'dragover'].forEach(e =>
  dropZone.addEventListener(e, ev => { ev.preventDefault(); dropZone.classList.add('dragging') })
)
;['dragleave', 'drop'].forEach(e =>
  dropZone.addEventListener(e, ev => { ev.preventDefault(); dropZone.classList.remove('dragging') })
)
dropZone.addEventListener('drop', ev => {
  const f = ev.dataTransfer.files[0]
  if (f) setFile(f)
})
fileInput.addEventListener('change', () => {
  if (fileInput.files[0]) setFile(fileInput.files[0])
})

// ── File selection ────────────────────────────────────
function fmt(b) {
  if (b < 1024)        return b + ' B'
  if (b < 1048576)     return (b / 1024).toFixed(1) + ' KB'
  return (b / 1048576).toFixed(1) + ' MB'
}

function setFile(file) {
  if (file.type !== 'image/png') { showError('Only PNG files are supported.'); return }
  selectedFile = file
  previewName.textContent = file.name
  previewSize.textContent = fmt(file.size)
  const reader = new FileReader()
  reader.onloadend = () => { previewThumb.src = reader.result }
  reader.readAsDataURL(file)
  previewCard.classList.add('visible')
  btnConvert.classList.add('visible')
  hideError()
  resetResult()
}

function clearFile() {
  selectedFile    = null
  fileInput.value = ''
  previewCard.classList.remove('visible')
  btnConvert.classList.remove('visible')
  previewThumb.src = ''
  resetResult()
  hideError()
}

btnClear.addEventListener('click', clearFile)

// ── Upload ────────────────────────────────────────────
btnConvert.addEventListener('click', () => { if (selectedFile) upload(selectedFile) })

function upload(file) {
  btnConvert.disabled = true
  progressFill.style.width = '0%'
  progressLabel.textContent = 'Uploading…'
  progressPct.textContent   = ''
  progressWrap.classList.add('visible')
  hideError()
  resetResult()

  const fd  = new FormData()
  fd.append('file', file)
  const xhr = new XMLHttpRequest()
  xhr.open('POST', `${API}/upload`)

  xhr.upload.addEventListener('progress', e => {
    if (!e.lengthComputable) return
    const pct = Math.round(e.loaded / e.total * 100)
    progressFill.style.width  = pct + '%'
    progressPct.textContent   = pct + '%'
  })

  xhr.addEventListener('load', () => {
    progressFill.style.width  = '100%'
    progressLabel.textContent = 'Processing…'
    progressPct.textContent   = ''

    if (xhr.status === 200) {
      const data = JSON.parse(xhr.responseText)
      setTimeout(() => showResult(data.url), 400)
    } else {
      let msg = 'Upload failed.'
      try { msg = JSON.parse(xhr.responseText).detail || msg } catch {}
      showError(msg)
      progressWrap.classList.remove('visible')
    }
    btnConvert.disabled = false
  })

  xhr.addEventListener('error', () => {
    showError('Network error — is the API running on port 8080?')
    progressWrap.classList.remove('visible')
    btnConvert.disabled = false
  })

  xhr.send(fd)
}

// ── Result ────────────────────────────────────────────
function showResult(url) {
  progressWrap.classList.remove('visible')
  resultImg.src       = url
  resultUrl.textContent = url
  resultCard.classList.add('visible')
}

function resetResult() {
  resultCard.classList.remove('visible')
  resultImg.src         = ''
  resultUrl.textContent = ''
  progressWrap.classList.remove('visible')
  progressFill.style.width = '0%'
  btnConvert.disabled = false
}

// ── Error ─────────────────────────────────────────────
function showError(msg) {
  errorMsg.textContent = msg
  errorMsg.classList.add('visible')
}

function hideError() { errorMsg.classList.remove('visible') }

// ── Copy URL ──────────────────────────────────────────
btnCopy.addEventListener('click', () => {
  navigator.clipboard.writeText(resultUrl.textContent).then(() => {
    btnCopy.textContent = 'Copied!'
    btnCopy.classList.add('copied')
    setTimeout(() => {
      btnCopy.textContent = 'Copy URL'
      btnCopy.classList.remove('copied')
    }, 2000)
  })
})
