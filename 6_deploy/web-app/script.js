// Enhanced Virtual Coffee Shop Script - Version 2.0 with Bulletproof Loading Animation
console.log('🚀 Loading Enhanced Script v2.0 - Bulletproof Animation Edition');

const chatbotForm = document.getElementById('chatbot-form');
const chatbotInput = document.getElementById('chatbot-input');
const chatbotMessages = document.getElementById('chatbot-messages');
const signOutButton = document.getElementById('signOutButton');

let sessionId = localStorage.getItem('chatbot_session_id') || null;
let websocket = null;
let websocketUrl = null;
let isConnected = false;
let reconnectAttempts = 0;
const maxReconnectAttempts = 5;

// Generate session ID if not exists
if (!sessionId) {
    sessionId = 'session_' + Math.random().toString(36).substr(2, 9);
    localStorage.setItem('chatbot_session_id', sessionId);
}

// Load WebSocket configuration
async function loadWebSocketConfig() {
    try {
        const response = await fetch('websocket-config.json');
        const config = await response.json();
        websocketUrl = config.websocketUrl;
        console.log('WebSocket URL loaded:', websocketUrl);
        return true;
    } catch (error) {
        console.error('Failed to load WebSocket config:', error);
        // Fallback to REST API if WebSocket config is not available
        return false;
    }
}

// Add sign out functionality
if (signOutButton) {
    signOutButton.addEventListener('click', function() {
        // Close WebSocket connection
        if (websocket) {
            websocket.close();
        }
        // Clear session storage
        sessionStorage.removeItem('idToken');
        // Redirect to login page
        window.location.href = 'login.html';
    });
}

function addMessage(content, sender = 'bot', messageType = 'normal') {
    const msg = document.createElement('div');
    msg.className = sender === 'bot' ? 'bot-message' : 'user-message';
    
    // Add special styling for different message types
    if (messageType === 'processing') {
        msg.classList.add('processing-message');
        msg.id = 'loading-' + Date.now();
        
        // Enhanced loading UI with animated steps
        msg.innerHTML = `
          <div class="loading-content">
            <div class="spinner"></div>
            <div class="loading-text">
              <div class="loading-step">🔍 Analyzing your query...</div>
              <div class="loading-step">🧠 Connecting with Knowledge Base...</div>
              <div class="loading-step">✨ Forming response...</div>
            </div>
          </div>
        `;
        
        // Don't start animation here - wait until after DOM insertion
        
    } else if (messageType === 'progress') {
        msg.classList.add('progress-message');
        msg.textContent = content;
    } else if (messageType === 'error') {
        msg.classList.add('error-message');
        msg.textContent = content;
    } else {
        // Format content for better readability
        if (sender === 'bot') {
            // Process bot messages for better formatting
            let formattedContent = content
                // Convert numbered lists (1. 2. 3.) to proper formatting
                .replace(/(\d+\.\s)/g, '\n$1')
                // Convert bullet points (- or •) to proper formatting
                .replace(/([•\-]\s)/g, '\n$1')
                // Add line breaks before "Keep in mind" or similar phrases
                .replace(/(Keep in mind that:|Additionally,|However,|Please note:|Would you like)/g, '\n\n$1')
                // Clean up multiple consecutive line breaks
                .replace(/\n{3,}/g, '\n\n')
                // Trim leading/trailing whitespace
                .trim();
            
            // Use innerHTML to preserve line breaks and convert \n to <br>
            msg.innerHTML = formattedContent.replace(/\n/g, '<br>');
        } else {
            // For user messages, use textContent to prevent XSS
            msg.textContent = content;
        }
    }
    
    chatbotMessages.appendChild(msg);
    chatbotMessages.scrollTop = chatbotMessages.scrollHeight;
    
    // Start loading animation AFTER DOM insertion for processing messages
    if (messageType === 'processing') {
        // Use setTimeout to ensure DOM is fully rendered
        setTimeout(() => {
            console.log('🎬 Starting animation for:', msg.id);
            animateLoadingSteps(msg.id);
        }, 50);
    }
    
    return msg;
}

function updateLastBotMessage(content) {
    const botMessages = chatbotMessages.querySelectorAll('.bot-message');
    if (botMessages.length > 0) {
        const lastMessage = botMessages[botMessages.length - 1];
        
        // Apply the same formatting logic as addMessage for bot messages
        let formattedContent = content
            // Convert numbered lists (1. 2. 3.) to proper formatting
            .replace(/(\d+\.\s)/g, '\n$1')
            // Convert bullet points (- or •) to proper formatting
            .replace(/([•\-]\s)/g, '\n$1')
            // Add line breaks before "Keep in mind" or similar phrases
            .replace(/(Keep in mind that:|Additionally,|However,|Please note:|Would you like)/g, '\n\n$1')
            // Clean up multiple consecutive line breaks
            .replace(/\n{3,}/g, '\n\n')
            // Trim leading/trailing whitespace
            .trim();
        
        // Use innerHTML to preserve line breaks and convert \n to <br>
        lastMessage.innerHTML = formattedContent.replace(/\n/g, '<br>');
    }
}

function removeProcessingMessages() {
    const processingMessages = chatbotMessages.querySelectorAll('.processing-message, .progress-message');
    
    processingMessages.forEach(msg => {
        // Clear any loading intervals to prevent memory leaks
        if (msg.dataset.loadingInterval) {
            clearInterval(parseInt(msg.dataset.loadingInterval));
        }
        
        // Complete the final step (Forming response) before removal
        const finalStep = msg.querySelector('.loading-step:last-child');
        if (finalStep && finalStep.classList.contains('active')) {
            finalStep.classList.remove('active');
            finalStep.classList.add('completed');
            console.log('✅ Final step completed: Forming response...');
        }
        
        // Check timing conditions
        const startTime = parseInt(msg.dataset.startTime) || 0;
        const minimumDuration = parseInt(msg.dataset.minimumDuration) || 6000; // Updated to 6 seconds
        const animationReady = msg.dataset.animationCompleted === 'ready';
        const elapsed = Date.now() - startTime;
        
        console.log(`🔍 Checking removal conditions for loading message:`, {
            elapsed,
            minimumDuration,
            animationReady,
            shouldWait: elapsed < minimumDuration && !animationReady
        });
        
        if (elapsed >= minimumDuration || animationReady) {
            // Conditions met - remove with smooth fade after showing final completion
            console.log('✅ Removing loading message - response arrived!');
            
            // Brief pause to show the final checkmark, then fade out
            setTimeout(() => {
                msg.style.transition = 'opacity 0.5s ease-out, transform 0.5s ease-out';
                msg.style.opacity = '0';
                msg.style.transform = 'translateY(-10px)';
                setTimeout(() => {
                    if (msg.parentNode) {
                        msg.remove();
                    }
                }, 500);
            }, 800); // 800ms pause to show final checkmark
            
        } else {
            // Wait for minimum conditions
            const remainingTime = minimumDuration - elapsed;
            console.log(`⏳ Waiting ${remainingTime}ms more for loading animation timing`);
            
            setTimeout(() => {
                console.log('🎬 Final removal after waiting');
                
                // Complete final step if not already done
                const finalStepCheck = msg.querySelector('.loading-step:last-child');
                if (finalStepCheck && finalStepCheck.classList.contains('active')) {
                    finalStepCheck.classList.remove('active');
                    finalStepCheck.classList.add('completed');
                }
                
                // Remove with fade
                setTimeout(() => {
                    msg.style.transition = 'opacity 0.5s ease-out, transform 0.5s ease-out';
                    msg.style.opacity = '0';
                    msg.style.transform = 'translateY(-10px)';
                    setTimeout(() => {
                        if (msg.parentNode) {
                            msg.remove();
                        }
                    }, 500);
                }, 800);
            }, remainingTime);
        }
    });
}

// Function to animate loading steps with bulletproof timing
function animateLoadingSteps(loadingId) {
    const steps = document.querySelectorAll(`#${loadingId} .loading-step`);
    if (!steps || steps.length === 0) {
        console.warn('No loading steps found for ID:', loadingId);
        return;
    }
    
    let currentStep = 0;
    const stepDuration = 2000; // Increased to 2 seconds per step
    const minimumTotalDuration = 6000; // Minimum 6 seconds total (3 steps × 2s)
    
    console.log('🎬 Starting bulletproof loading animation for:', loadingId);
    
    // Ensure first step is active immediately
    if (steps[0]) {
        steps[0].classList.remove('active'); // Reset first
        setTimeout(() => steps[0].classList.add('active'), 50); // Add with slight delay for visual effect
    }
    
    // Create animation sequence with longer timing
    const animationSequence = [
        { step: 0, action: 'activate', delay: 0 },
        { step: 0, action: 'complete', delay: stepDuration },
        { step: 1, action: 'activate', delay: stepDuration + 100 },
        { step: 1, action: 'complete', delay: stepDuration * 2 + 100 },
        { step: 2, action: 'activate', delay: stepDuration * 2 + 200 },
        // NOTE: Step 2 (Forming response) stays active until response arrives - no completion here
    ];
    
    // Execute animation sequence with guaranteed timing
    animationSequence.forEach(({ step, action, delay }) => {
        setTimeout(() => {
            if (steps[step]) {
                if (action === 'activate') {
                    steps[step].classList.add('active');
                    console.log(`✨ Step ${step + 1} activated:`, steps[step].textContent.trim());
                } else if (action === 'complete') {
                    steps[step].classList.remove('active');
                    steps[step].classList.add('completed');
                    console.log(`✅ Step ${step + 1} completed:`, steps[step].textContent.trim());
                }
            }
        }, delay);
    });
    
    // Store timing info for removal logic
    const loadingElement = document.getElementById(loadingId);
    if (loadingElement) {
        loadingElement.dataset.startTime = Date.now();
        loadingElement.dataset.minimumDuration = minimumTotalDuration;
        loadingElement.dataset.animationCompleted = 'false';
        
        // Mark animation as "ready for completion" after sequence finishes (but keep final step active)
        setTimeout(() => {
            loadingElement.dataset.animationCompleted = 'ready'; // Changed from 'true' to 'ready'
            console.log('🎯 Loading animation ready for completion (final step still active):', loadingId);
        }, stepDuration * 2 + 300); // After first 2 steps complete
    }
}

// Debug function to check loading animation state
function debugLoadingAnimation(loadingId) {
    const element = document.getElementById(loadingId);
    if (!element) {
        console.log('Loading element not found:', loadingId);
        return;
    }
    
    const steps = element.querySelectorAll('.loading-step');
    console.log('Loading animation debug for:', loadingId);
    console.log('Total steps:', steps.length);
    
    steps.forEach((step, index) => {
        const classes = Array.from(step.classList);
        console.log(`Step ${index + 1}:`, step.textContent.trim(), 'Classes:', classes);
    });
    
    console.log('Start time:', element.dataset.startTime);
    console.log('Minimum duration:', element.dataset.minimumDuration);
    console.log('Elapsed time:', Date.now() - parseInt(element.dataset.startTime || 0));
}

function initializeWebSocket() {
    if (!websocketUrl) {
        console.error('WebSocket URL not available');
        return false;
    }

    try {
        websocket = new WebSocket(websocketUrl);
        
        websocket.onopen = function(event) {
            console.log('WebSocket connected');
            isConnected = true;
            reconnectAttempts = 0;
            
            // Update connection status
            updateConnectionStatus('connected');
        };
        
        websocket.onmessage = function(event) {
            try {
                const data = JSON.parse(event.data);
                handleWebSocketMessage(data);
            } catch (error) {
                console.error('Error parsing WebSocket message:', error);
            }
        };
        
        websocket.onclose = function(event) {
            console.log('WebSocket disconnected:', event.code, event.reason);
            isConnected = false;
            updateConnectionStatus('disconnected');
            
            // Attempt to reconnect if not a normal closure
            if (event.code !== 1000 && reconnectAttempts < maxReconnectAttempts) {
                setTimeout(() => {
                    reconnectAttempts++;
                    console.log(`Reconnection attempt ${reconnectAttempts}/${maxReconnectAttempts}`);
                    initializeWebSocket();
                }, 2000 * reconnectAttempts);
            }
        };
        
        websocket.onerror = function(error) {
            console.error('WebSocket error:', error);
            updateConnectionStatus('error');
        };
        
        return true;
    } catch (error) {
        console.error('Failed to initialize WebSocket:', error);
        return false;
    }
}

function handleWebSocketMessage(data) {
    console.log('Received WebSocket message:', data);
    
    switch (data.type) {
        case 'connection':
            addMessage(data.message, 'bot');
            break;
            
        case 'processing':
            addMessage(data.message, 'bot', 'processing');
            break;
            
        case 'progress':
            // Don't remove processing messages - let the spinning wheel continue
            // Progress messages from server are just status updates, keep the dynamic loading
            console.log('Progress update:', data.message);
            break;
            
        case 'streaming':
            // Handle partial responses (if implemented)
            updateLastBotMessage(data.partial_response);
            break;
            
        case 'response':
            // Remove processing messages and show final response
            removeProcessingMessages();
            addMessage(data.message, 'bot');
            break;
            
        case 'error':
            removeProcessingMessages();
            addMessage(data.message, 'bot', 'error');
            break;
            
        case 'ping':
            // Respond to ping with pong (keep-alive)
            if (websocket && websocket.readyState === WebSocket.OPEN) {
                websocket.send(JSON.stringify({type: 'pong'}));
            }
            break;
            
        default:
            console.log('Unknown message type:', data.type);
    }
}

function updateConnectionStatus(status) {
    // Create or update connection status indicator
    let statusIndicator = document.getElementById('connection-status');
    if (!statusIndicator) {
        statusIndicator = document.createElement('div');
        statusIndicator.id = 'connection-status';
        statusIndicator.className = 'connection-status';
        document.body.appendChild(statusIndicator);
    }
    
    statusIndicator.className = `connection-status ${status}`;
    
    switch (status) {
        case 'connected':
            statusIndicator.textContent = '🟢 Connected';
            break;
        case 'disconnected':
            statusIndicator.textContent = '🔴 Disconnected';
            break;
        case 'error':
            statusIndicator.textContent = '⚠️ Connection Error';
            break;
        default:
            statusIndicator.textContent = '⚪ Unknown';
    }
}

async function sendMessageViaWebSocket(message) {
    if (!websocket || websocket.readyState !== WebSocket.OPEN) {
        throw new Error('WebSocket not connected');
    }
    
    // Get user ID from session storage (set during Cognito authentication)
    const userId = sessionStorage.getItem('userId');
    const username = sessionStorage.getItem('username');
    
    const messageData = {
        message: message,
        session_id: sessionId,
        user_id: userId,
        username: username
    };
    
    websocket.send(JSON.stringify(messageData));
}

// Fallback REST API function
async function sendMessageToAPI(message) {
    const apiUrl = 'https://u4o1pk2v4i.execute-api.eu-central-1.amazonaws.com/prod/chatbot';
    
    // Get user ID from session storage (set during Cognito authentication)
    const userId = sessionStorage.getItem('userId');
    const username = sessionStorage.getItem('username');
    
    try {
        const response = await fetch(apiUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                prompt: message,  // Use 'prompt' for REST API
                session_id: sessionId,
                user_id: userId,
                username: username
            })
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        const data = await response.json();
        
        // The Lambda function returns response directly in data.response
        let botReply = "Sorry, I didn't understand that.";
        if (data.response) {
            botReply = data.response;
        } else if (data.error) {
            botReply = `Error: ${data.error}`;
        } else if (data.message) {
            botReply = data.message;
        }
        
        return botReply;
    } catch (err) {
        console.error('API Error:', err);
        return "Sorry, I'm having trouble connecting to the server.";
    }
}

chatbotForm.addEventListener('submit', async function(e) {
    e.preventDefault();
    const userInput = chatbotInput.value.trim();
    if (!userInput) return;
    
    addMessage(userInput, 'user');
    chatbotInput.value = '';
    
    try {
        if (isConnected && websocket) {
            // Use WebSocket
            await sendMessageViaWebSocket(userInput);
        } else {
            // Fallback to REST API
            console.log('Using REST API fallback');
            addMessage("", 'bot', 'processing'); // Empty content since we generate dynamic content
            const botResponse = await sendMessageToAPI(userInput);
            removeProcessingMessages();
            addMessage(botResponse, 'bot');
        }
    } catch (error) {
        console.error('Error sending message:', error);
        removeProcessingMessages();
        addMessage("Sorry, I'm having trouble connecting to the server.", 'bot', 'error');
    }
});

// Function to send sample prompts
function sendSamplePrompt(prompt) {
    // Set the input value and trigger the form submission
    chatbotInput.value = prompt;
    chatbotForm.dispatchEvent(new Event('submit'));
}

// Initialize the application
async function initializeApp() {
    console.log('Initializing application...');
    
    // Try to load WebSocket configuration and connect
    const configLoaded = await loadWebSocketConfig();
    if (configLoaded) {
        const wsConnected = initializeWebSocket();
        if (!wsConnected) {
            console.log('WebSocket initialization failed, will use REST API fallback');
        }
    } else {
        console.log('WebSocket config not available, using REST API only');
    }
}

// Start the application when page loads
document.addEventListener('DOMContentLoaded', initializeApp);
