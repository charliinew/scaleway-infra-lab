/**
 * imgflow — Image Converter
 * Minimalist frontend logic
 */

const API_BASE = window.location.origin;

// DOM Elements
const els = {
    form: document.getElementById('upload-form'),
    dropzone: document.getElementById('dropzone'),
    fileInput: document.getElementById('file-input'),
    fileName: document.getElementById('fileName'), // wait, I used file-name in HTML
    qualityRange: document.getElementById('quality'),
    qualityVal: document.getElementById('quality-val'),
    submitBtn: document.getElementById('submit-btn'),
    
    // Status
    statusDot: document.getElementById('status-dot'),
    statusText: document.getElementById('status-text'),
    
    // Results
    results: document.getElementById('results'),
    resultImg: document.getElementById('result-img'),
    resultUrl: document.getElementById('result-url'),
    resultAlt: document.getElementById('result-alt'),
    altContainer: document.getElementById('alt-container'),
    snippetsContainer: document.getElementById('snippets-container'),
    resultHtml: document.getElementById('result-html'),
    resultReact: document.getElementById('result-react'),
    statsContainer: document.getElementById('stats-container'),
    statOriginal: document.getElementById('stat-original'),
    statConverted: document.getElementById('stat-converted'),
    statRatio: document.getElementById('stat-ratio'),
    
    // Error
    errorToast: document.getElementById('error-toast'),
    errorMessage: document.getElementById('error-message')
};

// Fix fileName reference
els.fileName = document.getElementById('file-name');

// Initialization
document.addEventListener('DOMContentLoaded', () => {
    checkHealth();
    setupEventListeners();
});

// Event Listeners
function setupEventListeners() {
    // Quality slider
    els.qualityRange.addEventListener('input', (e) => {
        els.qualityVal.textContent = `${e.target.value}%`;
    });

    // File selection
    els.fileInput.addEventListener('change', handleFileSelect);

    // Drag and Drop
    ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
        els.dropzone.addEventListener(eventName, preventDefaults, false);
    });

    ['dragenter', 'dragover'].forEach(eventName => {
        els.dropzone.addEventListener(eventName, highlight, false);
    });

    ['dragleave', 'drop'].forEach(eventName => {
        els.dropzone.addEventListener(eventName, unhighlight, false);
    });

    els.dropzone.addEventListener('drop', handleDrop, false);

    // Form submit
    els.form.addEventListener('submit', handleSubmit);
}

// Utility Functions
function preventDefaults(e) {
    e.preventDefault();
    e.stopPropagation();
}

function highlight() {
    els.dropzone.classList.add('border-brand-500', 'bg-brand-50');
    els.dropzone.classList.remove('border-gray-200', 'bg-gray-50');
}

function unhighlight() {
    els.dropzone.classList.remove('border-brand-500', 'bg-brand-50');
    els.dropzone.classList.add('border-gray-200', 'bg-gray-50');
}

function formatBytes(bytes, decimals = 2) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const dm = decimals < 0 ? 0 : decimals;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
}

// Actions
function handleFileSelect(e) {
    const file = e.target.files[0];
    if (file) {
        if (file.type !== 'image/png') {
            showError('Please select a valid PNG file.');
            els.fileInput.value = '';
            els.fileName.textContent = 'Click or drag a PNG file';
            return;
        }
        els.fileName.textContent = file.name;
        els.fileName.classList.add('text-brand-600');
    }
}

function handleDrop(e) {
    const dt = e.dataTransfer;
    const files = dt.files;
    
    if (files.length) {
        els.fileInput.files = files;
        handleFileSelect({ target: { files: files } });
    }
}

async function checkHealth() {
    try {
        const res = await fetch(`${API_BASE}/health`);
        if (res.ok) {
            els.statusDot.className = "w-2 h-2 rounded-full bg-teal-500 shadow-[0_0_8px_rgba(20,184,166,0.6)] animate-pulse";
            els.statusText.textContent = "System Online";
            els.submitBtn.disabled = false;
        } else {
            throw new Error('API Offline');
        }
    } catch (err) {
        els.statusDot.className = "w-2 h-2 rounded-full bg-red-500 shadow-[0_0_8px_rgba(239,68,68,0.6)]";
        els.statusText.textContent = "System Offline";
        els.submitBtn.disabled = true;
        showError("Backend API is currently unreachable.");
    }
}

// Form Submission
async function handleSubmit(e) {
    e.preventDefault();
    hideError();
    
    const file = els.fileInput.files[0];
    if (!file) {
        showError("Please select a file to convert.");
        return;
    }
    
    setLoading(true);
    
    const formData = new FormData(els.form);
    
    // Checkbox doesn't serialize if unchecked. FastAPI prefers explicit true/false.
    if (els.form.elements['generate_alt'] && els.form.elements['generate_alt'].checked) {
        formData.set('generate_alt', 'true');
    } else {
        formData.set('generate_alt', 'false');
    }
    
    try {
        const response = await fetch(`${API_BASE}/upload`, {
            method: 'POST',
            body: formData
        });
        
        if (!response.ok) {
            let errorMsg = `HTTP Error ${response.status}`;
            try {
                const errData = await response.json();
                errorMsg = errData.detail || errorMsg;
            } catch (e) {}
            throw new Error(errorMsg);
        }
        
        const data = await response.json();
        showResults(data);
        
    } catch (error) {
        showError(error.message);
    } finally {
        setLoading(false);
    }
}

function setLoading(isLoading) {
    els.submitBtn.disabled = isLoading;
    if (isLoading) {
        const originalText = els.submitBtn.innerHTML;
        els.submitBtn.dataset.original = originalText;
        els.submitBtn.innerHTML = `
            <svg class="animate-spin -ml-1 mr-2 h-5 w-5 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            </svg>
            Processing...
        `;
    } else {
        els.submitBtn.innerHTML = els.submitBtn.dataset.original || 'Convert Image';
    }
}

function showResults(data) {
    els.form.parentElement.classList.add('hidden');
    els.results.classList.remove('hidden');
    
    // Set Image
    const fullUrl = data.url.startsWith('http') ? data.url : `${API_BASE}${data.url.startsWith('/') ? '' : '/'}${data.url}`;
    els.resultImg.src = fullUrl;
    els.resultUrl.textContent = fullUrl;
    document.getElementById('download-btn').href = fullUrl;
    
    // Set Stats
    if (data.original_size && data.converted_size) {
        els.statsContainer.classList.remove('hidden');
        els.statOriginal.textContent = formatBytes(data.original_size);
        els.statConverted.textContent = formatBytes(data.converted_size);
        
        // Calculate ratio carefully
        let reduction = 0;
        if (data.compression_ratio) {
            // "25.0%" means it's 25% of the original size, so reduction is 75%
            const ratioValue = parseFloat(data.compression_ratio);
            reduction = Math.round(100 - ratioValue);
        } else {
            reduction = Math.round(100 - (data.converted_size / data.original_size) * 100);
        }
        
        // Show as e.g. -75% (or +10% if it got larger)
        if (reduction > 0) {
            els.statRatio.textContent = `-${reduction}%`;
            els.statRatio.className = 'text-xs font-bold text-green-600 mb-[2px]';
        } else if (reduction < 0) {
            els.statRatio.textContent = `+${Math.abs(reduction)}%`;
            els.statRatio.className = 'text-xs font-bold text-red-600 mb-[2px]';
        } else {
            els.statRatio.textContent = `0%`;
            els.statRatio.className = 'text-xs font-bold text-gray-500 mb-[2px]';
        }
    } else {
        els.statsContainer.classList.add('hidden');
    }
    
    // Set Alt text & Snippets
    els.snippetsContainer.classList.remove('hidden');
    let altText = "";

    if (data.alt_text && data.alt_text.alt_text) {
        els.altContainer.classList.remove('hidden');
        els.resultAlt.textContent = data.alt_text.alt_text;
        altText = data.alt_text.alt_text;
    } else {
        els.altContainer.classList.add('hidden');
    }
    
    // Snippets
    if (data.alt_text && data.alt_text.html_tag) {
        els.resultHtml.textContent = data.alt_text.html_tag.replace("{{image_url}}", fullUrl);
    } else {
        els.resultHtml.textContent = `<img src="${fullUrl}" alt="${altText}" />`;
    }
    
    if (data.alt_text && data.alt_text.react_component) {
        els.resultReact.textContent = data.alt_text.react_component.replace("{{image_url}}", fullUrl);
    } else {
        els.resultReact.textContent = `<img src="${fullUrl}" alt="${altText}" />`;
    }
}

function resetForm() {
    els.form.reset();
    els.fileInput.value = '';
    els.fileName.textContent = 'Click or drag a PNG file';
    els.fileName.classList.remove('text-brand-600');
    els.qualityVal.textContent = '80%';
    
    els.results.classList.add('hidden');
    els.snippetsContainer.classList.add('hidden');
    els.form.parentElement.classList.remove('hidden');
    hideError();
}

// Error Handling
function showError(msg) {
    els.errorMessage.textContent = msg;
    els.errorToast.classList.remove('hidden');
    
    // Auto hide after 5s
    setTimeout(hideError, 5000);
}

function hideError() {
    els.errorToast.classList.add('hidden');
}

// Clipboard (HTTP fallback included)
window.copyToClipboard = function(elementId, btn) {
    const el = document.getElementById(elementId);
    let text = el.innerText || el.textContent;
    
    if (elementId === 'result-url' || elementId === 'result-html' || elementId === 'result-react') {
        text = el.textContent; // prevent getting button inner text accidentally
    }
    
    const originalHtml = btn.innerHTML;
    
    const showSuccess = () => {
        btn.innerHTML = `<svg class="w-5 h-5 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"></path></svg>`;
        setTimeout(() => btn.innerHTML = originalHtml, 2000);
    };

    if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(showSuccess).catch(err => fallbackCopyTextToClipboard(text, showSuccess));
    } else {
        fallbackCopyTextToClipboard(text, showSuccess);
    }
};

function fallbackCopyTextToClipboard(text, successCallback) {
    const textArea = document.createElement("textarea");
    textArea.value = text;
    
    // Avoid scrolling to bottom
    textArea.style.top = "0";
    textArea.style.left = "0";
    textArea.style.position = "fixed";

    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();

    try {
        const successful = document.execCommand('copy');
        if (successful) successCallback();
    } catch (err) {
        console.error('Fallback: Oops, unable to copy', err);
        prompt("Copy to clipboard: Ctrl+C, Enter", text);
    }

    document.body.removeChild(textArea);
}
