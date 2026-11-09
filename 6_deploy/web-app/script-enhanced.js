// Tech Assistant Script - Direct AgentCore Integration
console.log('🚀 Loading Enhanced Script with Direct AgentCore Integration');

const ASSISTANT_NAME = 'Tech Assistant';

const chatbotForm = document.getElementById('chatbot-form');
const chatbotInput = document.getElementById('chatbot-input');
const chatbotMessages = document.getElementById('chatbot-messages');

let isInitialized = false;

// ---------------------------------------------------------------------------
// Application state
//
// The page runs in exactly one of three modes, and it says which one it is in:
//   live     — signed in, AgentCore client ready, answers come from the agent
//   preview  — deliberately offline (?preview=1); answers come from local page data
//   degraded — meant to be live but something failed; `reason` says what
// ---------------------------------------------------------------------------
const appState = {
    mode: 'live',
    reason: null,
    detail: null,
};

function setAppState(mode, reason = null, detail = null) {
    appState.mode = mode;
    appState.reason = reason;
    appState.detail = detail;
    console.log(`[state] mode=${mode}${reason ? ` reason=${reason}` : ''}`, detail || '');
    renderStateBanner();
}

// Human-readable copy for each failure reason. The first element is the chat
// headline, the second is the banner text. Only `agent-error` and `rate-limited`
// are actually the agent's fault — everything else used to be misreported as
// "the agent is offline", which sent people looking in the wrong place.
const FAILURE_COPY = {
    'not-signed-in': {
        headline: `You are not signed in, so I cannot reach the live ${ASSISTANT_NAME}.`,
        banner: 'Not signed in — live answers are unavailable.',
        action: 'signin',
    },
    'credentials-expired': {
        headline: `Your session expired, so I cannot reach the live ${ASSISTANT_NAME}.`,
        banner: 'Session expired — sign in again for live answers.',
        action: 'signin',
    },
    'access-denied': {
        headline: `This account is not authorised to call the ${ASSISTANT_NAME} runtime.`,
        banner: 'Access denied by AWS — check the Cognito role permissions.',
        action: null,
    },
    'not-configured': {
        headline: `The live ${ASSISTANT_NAME} is not configured for this deployment.`,
        banner: 'Agent endpoint not configured for this deployment.',
        action: null,
    },
    'network': {
        headline: `I could not reach the ${ASSISTANT_NAME} — the network request failed.`,
        banner: 'Network request to the agent failed — check your connection.',
        action: 'retry',
    },
    'rate-limited': {
        headline: `The ${ASSISTANT_NAME} is handling too many requests right now.`,
        banner: 'Agent is rate limited — try again shortly.',
        action: 'retry',
    },
    'agent-error': {
        headline: `The ${ASSISTANT_NAME} is temporarily unavailable.`,
        banner: 'Agent returned an error — it is temporarily unavailable.',
        action: 'retry',
    },
    'bad-request': {
        headline: `The ${ASSISTANT_NAME} could not process that request.`,
        banner: 'The agent rejected the last request.',
        action: null,
    },
    'unknown': {
        headline: `I could not get an answer from the ${ASSISTANT_NAME}.`,
        banner: 'The agent could not be reached.',
        action: 'retry',
    },
};

function failureCopy(reason) {
    return FAILURE_COPY[reason] || FAILURE_COPY.unknown;
}

// ---------------------------------------------------------------------------
// Connection status + state banner
// ---------------------------------------------------------------------------

// Driven by real events from the AgentCore client, never by a timer.
function setConnectionStatus(state, text) {
    const el = document.getElementById('connection-status');
    if (!el) return;
    el.textContent = text;
    el.className = `connection-status${state ? ` ${state}` : ''}`;
}

window.addEventListener('agentcore:status', function(event) {
    const { state, text } = event.detail || {};
    setConnectionStatus(state, text);
    // A successful call proves we are live again.
    if (state === 'connected' && appState.mode === 'degraded') {
        setAppState('live');
    }
});

// A banner that is impossible to miss, and that offers the way out.
function renderStateBanner() {
    const host = document.getElementById('app-state-banner');
    if (!host) return;

    if (appState.mode === 'live') {
        host.hidden = true;
        host.innerHTML = '';
        return;
    }

    const isPreview = appState.mode === 'preview';
    const copy = isPreview ? null : failureCopy(appState.reason);

    host.hidden = false;
    host.className = `app-state-banner ${isPreview ? 'preview' : 'degraded'}`;
    host.innerHTML = '';

    const text = document.createElement('span');
    text.className = 'app-state-banner-text';
    text.textContent = isPreview
        ? 'Preview mode: answers come from this page\u2019s local sample data, not the live agent.'
        : `Limited mode: ${copy.banner} Answers come from this page\u2019s local sample data.`;
    host.appendChild(text);

    const actions = document.createElement('span');
    actions.className = 'app-state-banner-actions';

    if (isPreview) {
        const exit = document.createElement('button');
        exit.type = 'button';
        exit.className = 'app-state-banner-btn';
        exit.textContent = 'Exit preview mode';
        exit.addEventListener('click', exitPreviewMode);
        actions.appendChild(exit);
    } else if (copy.action === 'signin') {
        const signIn = document.createElement('a');
        signIn.className = 'app-state-banner-btn';
        signIn.href = 'login.html';
        signIn.textContent = 'Sign in';
        actions.appendChild(signIn);
    } else if (copy.action === 'retry') {
        const retry = document.createElement('button');
        retry.type = 'button';
        retry.className = 'app-state-banner-btn';
        retry.textContent = 'Retry connection';
        retry.addEventListener('click', retryLiveConnection);
        actions.appendChild(retry);
    }

    if (appState.detail) {
        const details = document.createElement('span');
        details.className = 'app-state-banner-detail';
        details.title = appState.detail;
        details.textContent = 'Details in the browser console';
        actions.appendChild(details);
    }

    host.appendChild(actions);
}

// Leaving preview mode clears the sticky flag *and* the URL parameter (new and
// legacy), so a reload does not silently drop the user back into preview mode.
function exitPreviewMode() {
    if (window.CognitoAuth && typeof window.CognitoAuth.setPreviewMode === 'function') {
        window.CognitoAuth.setPreviewMode(false);
    } else {
        sessionStorage.removeItem('previewMode');
        sessionStorage.removeItem('demoMode');
    }
    const url = new URL(window.location.href);
    url.searchParams.delete('preview');
    url.searchParams.delete('demo');
    window.location.replace(url.toString());
}

async function retryLiveConnection() {
    setConnectionStatus('connecting', 'Reconnecting...');
    try {
        await connectLiveServices();
        setAppState('live');
        setConnectionStatus('connected', 'Connected');
        addMessage(`Reconnected — I can reach the ${ASSISTANT_NAME} again.`, 'bot');
    } catch (error) {
        const reason = error.reason || 'unknown';
        setAppState('degraded', reason, error.message);
        setConnectionStatus('error', 'Disconnected');
        addMessage(`Still cannot connect. ${failureCopy(reason).headline}`, 'bot');
    }
}

// Load config and initialise the agent client. Throws a reason-tagged error.
async function connectLiveServices() {
    if (window.CognitoAuth && typeof window.CognitoAuth.loadCognitoConfig === 'function') {
        await window.CognitoAuth.loadCognitoConfig();
        console.log('✅ Cognito configuration loaded');
    }
    if (!window.fixedAgentCoreClient || typeof window.fixedAgentCoreClient.initialize !== 'function') {
        const err = new Error('AgentCore client script did not load');
        err.reason = 'not-configured';
        throw err;
    }
    await window.fixedAgentCoreClient.initialize();
    console.log('✅ AgentCore client initialized');
}

// Single source of truth for signing out: clears all session state via CognitoAuth.
let signOutWired = false;
function wireSignOut() {
    if (signOutWired) return;
    const signOutButton = document.getElementById('signOutButton');
    if (!signOutButton) return;
    signOutWired = true;
    signOutButton.addEventListener('click', function(e) {
        e.preventDefault();
        if (!confirm('Are you sure you want to sign out?')) return;
        if (window.CognitoAuth && typeof window.CognitoAuth.signOut === 'function') {
            window.CognitoAuth.signOut();
        } else {
            ['idToken', 'awsCredentials', 'userId', 'username', 'selectedStore', 'previewMode', 'demoMode', 'redirectedToLogin']
                .forEach(key => sessionStorage.removeItem(key));
            try { localStorage.removeItem('chatbot_session_id'); } catch { /* ignore */ }
            window.location.replace('login.html');
        }
    });
}

// Initialize the application
async function initializeApp() {
    console.log('Initializing application...');
    
    wireSignOut();
    
    const previewMode = (window.CognitoAuth && typeof window.CognitoAuth.isPreviewMode === 'function')
        ? window.CognitoAuth.isPreviewMode()
        : sessionStorage.getItem('previewMode') === '1' || sessionStorage.getItem('demoMode') === '1';
    
    if (previewMode) {
        setAppState('preview');
        setConnectionStatus('preview', 'Preview mode');
    } else {
        setConnectionStatus('connecting', 'Connecting...');
        try {
            await connectLiveServices();
            setAppState('live');
            // Status stays "Connecting..." until the first call proves the
            // round trip works; claiming "Connected" here would be a guess.
            setConnectionStatus('connecting', 'Ready');
        } catch (error) {
            // Do NOT swallow this. Record why, and show it.
            console.error('❌ Live services unavailable:', error);
            setAppState('degraded', error.reason || 'unknown', error.message);
            setConnectionStatus('error', 'Disconnected');
        }
    }
    
    // Store data loads from index.html's own DOMContentLoaded handler.
    
    isInitialized = true;
    console.log(`✅ Application initialized (mode: ${appState.mode})`);
    
    if (chatbotMessages) {
        chatbotMessages.innerHTML = '';
    }
    
    addPersonalizedGreeting();
    
    if (appState.mode === 'preview') {
        addMessage(`Preview mode is on, so I answer from this page\u2019s local sample data instead of the live ${ASSISTANT_NAME}. Use "Exit preview mode" in the banner above to connect for real.`, 'bot');
    } else if (appState.mode === 'degraded') {
        const copy = failureCopy(appState.reason);
        addMessage(`${copy.headline} I can still show you the sample products, store locations and promotions stored on this page.`, 'bot');
    } else {
        addMessage('Welcome to the Cyberport Tech Assistant! I can help you choose a smartphone or laptop, check stock in a store, place a click & collect order, track an order, and answer questions about payments and promotions. How can I help you today?', 'bot');
    }
}

// Add personalized greeting
function addPersonalizedGreeting() {
    // Get username from session storage
    const username = sessionStorage.getItem('username');
    
    // Get current time and determine greeting
    const now = new Date();
    const hour = now.getHours();
    
    let timeGreeting;
    if (hour >= 5 && hour < 12) {
        timeGreeting = "Good morning";
    } else if (hour >= 12 && hour < 17) {
        timeGreeting = "Good afternoon";
    } else {
        timeGreeting = "Good evening";
    }
    
    // Create personalized greeting
    let greeting;
    if (username) {
        greeting = `${timeGreeting}, ${username}! What would you like to order today?`;
    } else {
        greeting = `${timeGreeting}! What would you like to order today?`;
    }
    
    // Add as first message
    addMessage(greeting, 'bot');
    console.log('Personalized greeting added:', greeting);
}

// Store data and the store-locator dropdown are owned by the inline script in
// index.html: it holds the sample store list (as `storeData`) and drives the
// dropdown with the `.dropdown-container.active` class that enhanced-styles.css
// actually styles. It loads that data from its own DOMContentLoaded handler.
//
// This file previously carried a second, conflicting copy of all of it. Because
// both are plain top-level declarations in the same global scope, index.html's
// copy simply overwrote this one — so the version here was dead code that also
// fetched a stores_records.json that is not deployed. Worse, its document-level
// click handler set an inline `display: none` on every `.dropdown-menu`, and an
// inline style beats a class rule: the stylesheet toggles opacity/visibility, so
// it could never undo that. After any click on the page, both dropdowns stopped
// opening for the rest of the session. The duplicate is removed.

// The model sometimes emits its internal deliberation in <thinking> tags. The
// runtime strips these too, but this is the last line of defence: customers must
// never read the agent reasoning about them. Handles an unclosed trailing tag,
// which is what a truncated response looks like.
const REASONING_TAGS = ['thinking', 'thought', 'reasoning', 'scratchpad', 'internal'];

function stripInternalReasoning(text) {
    if (typeof text !== 'string') return text;
    let out = text;
    REASONING_TAGS.forEach(tag => {
        out = out.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?</${tag}>`, 'gi'), '');
        // Unclosed opening tag: drop everything after it.
        out = out.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*$`, 'gi'), '');
        // Stray closing tag with no opener.
        out = out.replace(new RegExp(`</${tag}>`, 'gi'), '');
    });
    return out.replace(/\n{3,}/g, '\n\n').trim();
}

// Message handling
function addMessage(message, sender, isLoading = false) {
    const messageDiv = document.createElement('div');
    
    // Use the correct CSS classes that match the existing styles
    if (sender === 'bot') {
        messageDiv.classList.add('bot-message');
    } else if (sender === 'user') {
        messageDiv.classList.add('user-message');
    }
    
    if (isLoading) {
        messageDiv.classList.add('loading-message');
        messageDiv.innerHTML = `
            <div class="loading-content">
                <div class="spinner"></div>
                <span class="loading-text">Processing your request...</span>
            </div>
        `;
    } else {
        messageDiv.textContent = message;
    }
    
    chatbotMessages.appendChild(messageDiv);
    chatbotMessages.scrollTop = chatbotMessages.scrollHeight;
    
    return messageDiv;
}

function removeMessage(messageElement) {
    if (messageElement && messageElement.parentNode) {
        messageElement.parentNode.removeChild(messageElement);
    }
}

// Sample prompt functionality
function sendSamplePrompt(promptText) {
    const chatInput = document.getElementById('chatbot-input');
    if (chatInput) {
        chatInput.value = promptText;
        chatInput.focus();
        
        // Optional: Auto-send the message after a short delay
        setTimeout(() => {
            const chatForm = document.getElementById('chatbot-form');
            if (chatForm) {
                chatForm.dispatchEvent(new Event('submit'));
            }
        }, 500);
    }
}

// Make function globally available
window.sendSamplePrompt = sendSamplePrompt;

// Sample promotions kept on the page for preview and limited modes.
// Mirrors 2_data_strategy/promos/promos_records.json — the live agent reads the
// authoritative copy from the promotions API, so this list can lag behind.
const LOCAL_PROMOTIONS = [
    {"title": "Trade-in Bonus", "description": "Trade in your old smartphone or laptop and get an extra €50 on top of its trade-in value when you buy a new smartphone or laptop over €400.", "code": "TRADEIN50"},
    {"title": "Accessory Bundle Deal", "description": "10% off cases, chargers and screen protectors bought together with a new smartphone, when you order with your Cyberport customer account.", "code": ""},
    {"title": "Student Laptop Discount", "description": "10% off any new laptop, up to €150 off, with a valid student ID or university email address.", "code": "STUDENT10"},
    {"title": "Business Volume Discount", "description": "5% off orders of five or more laptops for business customers who order with a company name and VAT ID.", "code": "BUSINESS5"},
    {"title": "Gaming Laptop Bundle", "description": "Get a free gaming headset with any gaming laptop over €1,000.", "code": "GAMERBUNDLE"},
    {"title": "Refurbished Week", "description": "An extra 5% off all refurbished laptops.", "code": "REFURB5"},
    {"title": "0% Financing", "description": "Spread purchases of €299 or more over 6, 12 or 24 months at 0% interest, subject to a credit check by our financing partner.", "code": ""},
    {"title": "Newsletter Welcome Offer", "description": "€10 off your first online order of €100 or more after signing up for the newsletter.", "code": "WELCOME10"},
    {"title": "Black Friday Week", "description": "Up to 20% off selected smartphones and laptops. Discounted products are marked in the shop.", "code": ""}
];

// Client-side fallback for preview mode and for genuine failures.
//
// The headline states the real cause (from `error.reason`); the body is clearly
// labelled as this page's local sample data, because it is not a live lookup.
// Messages are rendered with textContent, so no markdown syntax here.
function handleAgentFallback(userInput, error) {
    const inputLower = userInput.toLowerCase();
    const reason = error && error.reason ? error.reason : null;
    
    // Determine the user's intent using keyword matching
    const isStoreQuery = inputLower.includes('store') || inputLower.includes('shop') ||
                         inputLower.includes('location') || inputLower.includes('branch') ||
                         inputLower.includes('address') || inputLower.includes('where') || 
                         inputLower.includes('hours') || inputLower.includes('open') || 
                         inputLower.includes('pickup station');
                         
    const isMenuQuery = inputLower.includes('product') || inputLower.includes('laptop') ||
                        inputLower.includes('phone') || inputLower.includes('iphone') ||
                        inputLower.includes('galaxy') || inputLower.includes('macbook') ||
                        inputLower.includes('price') || inputLower.includes('cost') ||
                        inputLower.includes('spec') || inputLower.includes('ram') ||
                        inputLower.includes('gaming') || inputLower.includes('compare') ||
                        inputLower.includes('recommend');
                        
    const isPromoQuery = inputLower.includes('promo') || inputLower.includes('deal') || 
                         inputLower.includes('discount') || inputLower.includes('coupon') || 
                         inputLower.includes('offer') || inputLower.includes('special');

    // Headline: preview mode is a choice, a failure is a failure, and each
    // failure names its own cause. Nothing here claims the agent is offline unless it is.
    let fallbackMsg;
    if (appState.mode === 'preview') {
        fallbackMsg = 'Preview mode is on, so this is not a live answer. ';
    } else {
        fallbackMsg = `${failureCopy(reason).headline} `;
    }

    // 1. Store queries — served from the sample store list on this page
    if (isStoreQuery) {
        fallbackMsg += "Here are the stores listed in this page's sample data:\n\n";
        const stores = (typeof storesData !== 'undefined' && storesData.length > 0) ? storesData : 
                       ((typeof storeData !== 'undefined' && storeData.length > 0) ? storeData : []);
                       
        if (stores.length > 0) {
            stores.forEach(store => {
                fallbackMsg += `📍 ${store.name}\n`;
                fallbackMsg += `   Address: ${store.address}, ${store.city}, ${store.state}\n`;
                fallbackMsg += `   Hours: ${store.hours_start} - ${store.hours_end}\n`;
                if (store.has_drive_thru) fallbackMsg += '   Pickup station: yes\n';
                fallbackMsg += '\n';
            });
            fallbackMsg += 'This is a sample subset and may not reflect current opening hours.';
        } else {
            fallbackMsg += "No store list is available on this page either. Try the 'Select Store' dropdown above.";
        }
        addMessage(fallbackMsg, 'bot');
        return;
    }

    // 2. Product queries — served from the sample catalogue embedded in index.html
    if (isMenuQuery) {
        fallbackMsg += "Here are the products in this page's sample data:\n\n";
        const menu = (typeof menuData !== 'undefined' && menuData.length > 0) ? menuData : [];
        
        if (menu.length > 0) {
            const categories = {};
            menu.forEach(item => {
                if (!categories[item.category]) categories[item.category] = [];
                categories[item.category].push(item.name);
            });
            Object.keys(categories).forEach(cat => {
                const label = cat.charAt(0).toUpperCase() + cat.slice(1).replace(/_/g, ' ');
                fallbackMsg += `📱 ${label}\n`;
                fallbackMsg += `   ${categories[cat].join(', ')}\n\n`;
            });
            fallbackMsg += "Expand 'Our Products' below for details. I cannot confirm current prices or " +
                           'store stock without the live agent.';
        } else {
            fallbackMsg += "No product data is available on this page either. Try the 'Our Products' section below.";
        }
        addMessage(fallbackMsg, 'bot');
        return;
    }

    // 3. Promotion queries — served from the sample promotion list above
    if (isPromoQuery) {
        fallbackMsg += "Here are the promotions in this page's sample data:\n\n";
        LOCAL_PROMOTIONS.forEach(promo => {
            fallbackMsg += `🎁 ${promo.title}\n`;
            fallbackMsg += `   ${promo.description}\n`;
            if (promo.code) fallbackMsg += `   Code: ${promo.code}\n`;
            fallbackMsg += '\n';
        });
        fallbackMsg += 'Please confirm availability in store — only the live agent sees current promotions.';
        addMessage(fallbackMsg, 'bot');
        return;
    }

    // 4. Anything needing the agent itself: orders, order status, payments
    fallbackMsg += 'Placing orders, checking order status and payment questions all need the ' +
                   'live agent, so I cannot help with those from this page. You can still browse ' +
                   'the products, store locations and promotions below.';
    addMessage(fallbackMsg, 'bot');
}

// Handle form submission
async function handleFormSubmit(event) {
    event.preventDefault();
    
    if (!isInitialized) {
        addMessage('Please wait while the application initializes...', 'bot');
        return;
    }
    
    const userInput = chatbotInput.value.trim();
    if (!userInput) return;
    
    // Add user message
    addMessage(userInput, 'user');
    
    // Clear input
    chatbotInput.value = '';
    
    // In preview or limited mode, answer locally and say so — do not pretend to
    // call the agent and then report the inevitable failure as an outage.
    const clientUsable = window.fixedAgentCoreClient &&
                         typeof window.fixedAgentCoreClient.sendMessage === 'function';
    
    if (appState.mode === 'preview') {
        handleAgentFallback(userInput, null);
        return;
    }
    
    if (!clientUsable) {
        handleAgentFallback(userInput, { reason: 'not-configured' });
        return;
    }
    
    if (appState.mode === 'degraded') {
        handleAgentFallback(userInput, { reason: appState.reason });
        return;
    }
    
    // Add loading message
    const loadingMessage = addMessage('', 'bot', true);
    
    try {
        // Get selected store if any
        const selectedStoreData = sessionStorage.getItem('selectedStore');
        const selectedStore = selectedStoreData ? JSON.parse(selectedStoreData) : null;
        
        // Stream the answer into the loading bubble: status lines while tools run, then the
        // text as it is written. The final "done" text replaces it (it is the cleaned answer).
        let streamedText = '';
        const bubble = loadingMessage;
        const showLoading = (statusText) => {
            bubble.classList.add('loading-message');
            bubble.classList.remove('streaming');
            bubble.innerHTML = '<div class="loading-content"><div class="spinner"></div><span class="loading-text"></span></div>';
            bubble.querySelector('.loading-text').textContent = statusText || 'Processing your request...';
        };
        const response = await window.fixedAgentCoreClient.sendMessage(userInput, {
            onStatus: (statusText) => {
                // Leading whitespace is not an answer yet: keep showing progress until real text arrives
                if (!stripInternalReasoning(streamedText)) showLoading(statusText);
                chatbotMessages.scrollTop = chatbotMessages.scrollHeight;
            },
            onDelta: (delta) => {
                streamedText += delta;
                const visible = stripInternalReasoning(streamedText);
                if (!visible) return;
                bubble.classList.remove('loading-message');
                bubble.classList.add('streaming');
                bubble.textContent = visible;
                chatbotMessages.scrollTop = chatbotMessages.scrollHeight;
            },
            onReset: () => {
                streamedText = '';
                showLoading('Working on it...');
            },
        });
        
        // The streamed bubble is replaced by the final answer below
        removeMessage(loadingMessage);
        
        // The runtime entrypoint returns a plain string, which the client wraps as
        // { message }. Accept the other common envelope keys too, so a payload
        // change shows the answer instead of "there was no response".
        const rawAnswer = response && (
            response.message || response.result || response.response || response.output || response.text
        );
        const answer = stripInternalReasoning(rawAnswer);
        
        if (typeof answer === 'string' && answer.trim()) {
            addMessage(answer, 'bot');
        } else if (typeof rawAnswer === 'string' && rawAnswer.trim()) {
            // The reply was nothing but internal reasoning — say so instead of
            // showing a blank bubble or leaking the reasoning.
            console.warn('Agent reply contained only internal reasoning:', rawAnswer);
            addMessage('I could not form a complete answer to that. Please try rephrasing.', 'bot');
        } else if (response && typeof response === 'object' && Object.keys(response).length > 0) {
            console.warn('Unrecognised agent payload shape:', response);
            addMessage(JSON.stringify(response, null, 2), 'bot');
        } else {
            addMessage('The agent accepted the request but returned an empty answer. Please try rephrasing.', 'bot');
        }
        
    } catch (error) {
        console.error('Error sending message:', error);
        
        // Remove loading message
        removeMessage(loadingMessage);
        
        // Reasons that need the user to act stick, so later messages do not
        // retry pointlessly. Transient ones leave the app live for a fresh try.
        const stickyReasons = ['not-signed-in', 'credentials-expired', 'access-denied', 'not-configured'];
        if (error.reason && stickyReasons.includes(error.reason)) {
            setAppState('degraded', error.reason, error.message);
        }
        
        // Answer from local data, with a headline that names the real cause
        handleAgentFallback(userInput, error);
    }
}

// Event listeners
if (chatbotForm) {
    chatbotForm.addEventListener('submit', handleFormSubmit);
}

// Initialize when DOM is loaded
document.addEventListener('DOMContentLoaded', function() {
    console.log('DOM loaded, initializing app...');
    initializeApp();
});

// Handle page visibility changes
document.addEventListener('visibilitychange', function() {
    if (!document.hidden && !isInitialized) {
        console.log('Page became visible, reinitializing...');
        initializeApp();
    }
});

console.log('Enhanced script loaded successfully');
