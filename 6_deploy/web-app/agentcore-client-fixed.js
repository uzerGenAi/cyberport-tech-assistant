// Every failure this client raises carries a machine-readable `reason` so the UI
// can say what actually went wrong instead of blaming the agent for everything.
// Keep these codes in sync with FAILURE_COPY in script-enhanced.js.
const AGENTCORE_REASONS = Object.freeze({
  NOT_SIGNED_IN: 'not-signed-in',
  CREDENTIALS_EXPIRED: 'credentials-expired',
  ACCESS_DENIED: 'access-denied',
  NOT_CONFIGURED: 'not-configured',
  BAD_REQUEST: 'bad-request',
  RATE_LIMITED: 'rate-limited',
  AGENT_ERROR: 'agent-error',
  NETWORK: 'network',
  UNKNOWN: 'unknown',
});

class FixedAgentCoreClient {
  constructor() {
    this.agentRuntimeArn = null;
    this.isInitialized = false;
    this.credentials = null;
    // 'unconfigured' | 'ready' | 'failed'
    this.status = 'unconfigured';
    this.lastFailure = null;

    this.LOCALSTORAGE_KEY = 'chatbot_session_id';
    this.sessionId = this.#initSession();
  }

  // Build an Error tagged with a reason code (and the HTTP details when known).
  #fail(message, reason, extra = {}) {
    const err = new Error(message);
    err.reason = reason;
    Object.assign(err, extra);
    this.lastFailure = { reason, message, ...extra };
    return err;
  }

  // Report connection state without touching the DOM: the page owns its own UI.
  #emitStatus(state, text) {
    try {
      window.dispatchEvent(new CustomEvent('agentcore:status', { detail: { state, text } }));
    } catch { /* CustomEvent unavailable — status display is non-essential */ }
  }

  // Translate an HTTP status into a reason the user can act on.
  #reasonForStatus(status) {
    if (status === 400 || status === 422) return AGENTCORE_REASONS.BAD_REQUEST;
    if (status === 401) return AGENTCORE_REASONS.CREDENTIALS_EXPIRED;
    if (status === 403) return AGENTCORE_REASONS.ACCESS_DENIED;
    if (status === 404) return AGENTCORE_REASONS.NOT_CONFIGURED;
    if (status === 429) return AGENTCORE_REASONS.RATE_LIMITED;
    if (status >= 500) return AGENTCORE_REASONS.AGENT_ERROR;
    return AGENTCORE_REASONS.UNKNOWN;
  }

  // === Session handling ===
  #safeLocalStorageGet(key) {
    try { return window.localStorage.getItem(key); } catch { return null; }
  }
  #safeLocalStorageSet(key, val) {
    try { window.localStorage.setItem(key, val); } catch { /* ignore */ }
  }
  #generateSessionId() {
    // Generate a UUID v4 (36 characters including hyphens) and prefix to ensure >=33 length always
    const uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
    return `session-${uuid}`; // total length 43 with prefix
  }
  #initSession() {
    const existing = this.#safeLocalStorageGet(this.LOCALSTORAGE_KEY);
    if (existing && typeof existing === 'string' && existing.trim() && existing.length >= 33) return existing;
    const fresh = this.#generateSessionId();
    this.#safeLocalStorageSet(this.LOCALSTORAGE_KEY, fresh);
    return fresh;
  }

  getSessionId() { return this.sessionId; }
  setSessionId(newId) {
    if (!newId || typeof newId !== 'string' || newId.length < 33) throw new Error('Invalid session id');
    this.sessionId = newId;
    this.#safeLocalStorageSet(this.LOCALSTORAGE_KEY, newId);
  }
  resetSession() {
    const fresh = this.#generateSessionId();
    this.setSessionId(fresh);
    console.log('Session reset. New session ID:', fresh);
    return fresh;
  }

  // === Initialization ===
  async initialize() {
    if (this.isInitialized) return; // idempotent
    try {
      console.log('Initializing Fixed AgentCore client...');

      // 1) Load AgentCore configuration
      await this.#loadAgentCoreConfig();
      console.log('AgentCore configuration loaded');

      // 2) Fetch AWS credentials via your Cognito wrapper
      console.log('Step 2: Getting AWS credentials...');
      this.credentials = await window.CognitoAuth.getCurrentAWSCredentials();
      console.log('AWS credentials obtained');

      // 3) Configure global AWS SDK
      AWS.config.update({
        region: 'eu-central-1',
        accessKeyId: this.credentials.accessKeyId,
        secretAccessKey: this.credentials.secretAccessKey,
        sessionToken: this.credentials.sessionToken,
      });

      this.isInitialized = true;
      this.status = 'ready';
      this.lastFailure = null;
      console.log('Fixed AgentCore client initialized successfully');
      console.log('Agent Runtime ARN:', this.agentRuntimeArn);
      console.log('Session ID:', this.sessionId);
    } catch (err) {
      console.error('Failed to initialize Fixed AgentCore client:', err);
      this.status = 'failed';
      // Preserve the underlying reason — an un-authenticated user and a missing
      // config file are different problems and deserve different messages.
      throw this.#fail(
        `AgentCore initialization failed: ${err.message}`,
        err.reason || AGENTCORE_REASONS.UNKNOWN,
      );
    }
  }

  async #loadAgentCoreConfig() {
    try {
      const resp = await fetch('agentcore-config.json', { cache: 'no-store' });
      if (!resp.ok) {
        throw this.#fail(
          `agentcore-config.json returned HTTP ${resp.status}`,
          AGENTCORE_REASONS.NOT_CONFIGURED,
        );
      }
      const cfg = await resp.json();
      if (!cfg || !cfg.agentRuntimeArn) {
        throw this.#fail(
          'agentRuntimeArn missing in agentcore-config.json',
          AGENTCORE_REASONS.NOT_CONFIGURED,
        );
      }
      this.agentRuntimeArn = cfg.agentRuntimeArn;
    } catch (e) {
      console.error('Failed to load AgentCore configuration:', e);
      if (!e.reason) e.reason = AGENTCORE_REASONS.NOT_CONFIGURED;
      throw e;
    }
  }

  // === Streaming (Server-Sent Events) ===
  // Reads the runtime's event stream and calls the handlers as events arrive.
  // Returns { message } with the final answer (the "done" event), like the JSON path.
  async #readStream(resp, handlers) {
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let finalText = null;
    let errorText = null;
    let streamed = '';
    const dispatch = (evt) => {
      if (!evt || typeof evt !== 'object') return;
      if (evt.type === 'status') handlers.onStatus && handlers.onStatus(evt.text || '');
      else if (evt.type === 'delta') { streamed += evt.text || ''; handlers.onDelta && handlers.onDelta(evt.text || ''); }
      else if (evt.type === 'reset') { streamed = ''; handlers.onReset && handlers.onReset(); }
      else if (evt.type === 'done') finalText = evt.text || '';
      else if (evt.type === 'error') errorText = evt.text || 'Something went wrong.';
    };
    for (;;) {
      const { value, done } = await reader.read();
      if (value) buffer += decoder.decode(value, { stream: true });
      if (done) buffer += decoder.decode();
      const parsed = agentcoreParseSSE(buffer, done);
      buffer = parsed.rest;
      parsed.events.forEach(dispatch);
      if (done) break;
    }
    if (finalText !== null) return { message: finalText };
    if (errorText !== null) return { message: errorText };
    return { message: streamed };
  }

  // === Messaging ===
  // handlers (optional): { onStatus(text), onDelta(text), onReset() } switches on streaming.
  async sendMessage(message, handlers = null) {
    const streaming = !!(handlers && (handlers.onDelta || handlers.onStatus));
    if (!this.isInitialized) await this.initialize();

    // --- build lightweight context from storage ---
    const userId = sessionStorage.getItem('username') || 'anonymous';
    let store = null;
    try { store = JSON.parse(sessionStorage.getItem('selectedStore') || 'null'); } catch {}
    const storeBits = store ? `; storeId=${store.store_id}; storeName="${store.name}"; storeCity="${store.city}"` : '';
    const ctxBlock = `[[CTX]] userId=${userId}${storeBits} [[/CTX]]\n`;
    const prompt = ctxBlock + message;
    // ------------------------------------------------

    const payload = JSON.stringify(streaming ? { prompt, stream: true } : { prompt });
    const baseUrl = 'https://bedrock-agentcore.eu-central-1.amazonaws.com';
    const runtimeArnEnc = encodeURIComponent(this.agentRuntimeArn);
    const session = encodeURIComponent(this.sessionId);
    const url = `${baseUrl}/runtimes/${runtimeArnEnc}/invocations?qualifier=DEFAULT&runtimeSessionId=${session}`;

    const { host } = new URL(url);
    const awsReq = new AWS.HttpRequest(url, 'eu-central-1');
    awsReq.method = 'POST';
    awsReq.headers = {
      'host': host,
      'content-type': 'application/json',
      'accept': streaming ? 'text/event-stream' : 'application/json',
      'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id': this.sessionId,
    };
    awsReq.body = payload;

    const maxRetries = 3;
    let attempt = 0;
    const baseDelay = 500; // base delay in ms

    // If a credential refresh fails mid-flight we remember why, so a follow-up
    // 403 is reported as an expired session rather than a permissions problem.
    let authFailureReason = null;

    while (true) {
      attempt++;
      try {
        // Clear previous AWS signatures to allow re-signing fresh request
        delete awsReq.headers['Authorization'];
        delete awsReq.headers['X-Amz-Date'];
        delete awsReq.headers['x-amz-date'];
        delete awsReq.headers['X-Amz-Security-Token'];
        delete awsReq.headers['x-amz-security-token'];

        const signer = new AWS.Signers.V4(awsReq, 'bedrock-agentcore');
        signer.addAuthorization(this.credentials, new Date());

        const resp = await fetch(url, { method: 'POST', headers: awsReq.headers, body: payload });
        
        if (!resp.ok) {
          const status = resp.status;
          const responseText = await resp.text();

          // 1. A 403 can mean expired credentials *or* a missing IAM permission.
          //    Try one refresh: if the refresh works and we still get 403, it is
          //    a genuine authorization problem, not an expiry.
          if (status === 403 && attempt <= maxRetries) {
            console.warn(`[AgentCore] Attempt ${attempt} failed with 403. Refreshing AWS credentials...`);
            try {
              this.credentials = await window.CognitoAuth.getCurrentAWSCredentials();
              AWS.config.update({
                accessKeyId: this.credentials.accessKeyId,
                secretAccessKey: this.credentials.secretAccessKey,
                sessionToken: this.credentials.sessionToken,
              });
              // retry immediately with new credentials
              continue;
            } catch (authErr) {
              console.error('[AgentCore] Failed to refresh credentials:', authErr);
              authFailureReason = authErr.reason || AGENTCORE_REASONS.CREDENTIALS_EXPIRED;
            }
          }

          // 2. Handle retriable server errors (429 Rate Limit, 5xx Server Errors)
          const isRetriable = status === 429 || (status >= 500 && status <= 599);
          if (isRetriable && attempt <= maxRetries) {
            console.warn(`[AgentCore] Attempt ${attempt} failed with status ${status}. Retrying...`);
            this.#emitStatus('connecting', `Retrying (${attempt}/${maxRetries})...`);

            // Exponential backoff with 20% randomized jitter
            const delay = baseDelay * Math.pow(2, attempt - 1);
            const jitter = delay * (0.8 + Math.random() * 0.4);
            await new Promise(resolve => setTimeout(resolve, jitter));
            continue;
          }

          this.#emitStatus('error', 'Disconnected');
          throw this.#fail(
            `HTTP ${status}: ${responseText}`,
            authFailureReason || this.#reasonForStatus(status),
            { httpStatus: status, responseText },
          );
        }

        // Reset connection status to connected on success
        this.#emitStatus('connected', 'Connected');
        this.lastFailure = null;

        const contentType = resp.headers.get('content-type') || '';
        if (streaming && contentType.includes('text/event-stream') && resp.body) {
          return await this.#readStream(resp, handlers);
        }

        const text = await resp.text();
        try {
          const parsed = JSON.parse(text);
          return typeof parsed === 'string' ? { message: parsed } : parsed;
        } catch {
          return { message: text || 'Empty response from agent' };
        }

      } catch (err) {
        // An error we already classified (e.g. the HTTP throw above) passes straight through.
        if (err.reason) {
          this.#emitStatus('error', 'Disconnected');
          throw err;
        }

        // Handle transient network errors (DNS, offline, CORS, TLS)
        const isNetworkError = err instanceof TypeError || err.message.includes('fetch') || err.message.includes('NetworkError');
        if (isNetworkError && attempt <= maxRetries) {
          console.warn(`[AgentCore] Attempt ${attempt} network error: ${err.message}. Retrying...`);
          this.#emitStatus('connecting', `Retrying (${attempt}/${maxRetries})...`);

          const delay = baseDelay * Math.pow(2, attempt - 1);
          const jitter = delay * (0.8 + Math.random() * 0.4);
          await new Promise(resolve => setTimeout(resolve, jitter));
          continue;
        }

        // Final failure after exhaustion or non-retriable error
        this.#emitStatus('error', 'Disconnected');
        throw this.#fail(
          err.message,
          isNetworkError ? AGENTCORE_REASONS.NETWORK : AGENTCORE_REASONS.UNKNOWN,
        );
      }
    }
  }


  // === Status ===
  isReady() { return this.isInitialized && !!this.credentials; }
  getLastFailure() { return this.lastFailure; }
}

// Split a Server-Sent Events buffer into parsed "data:" payloads.
// Returns { events, rest }: rest is the incomplete tail to keep for the next chunk.
function agentcoreParseSSE(buffer, final = false) {
  const events = [];
  const blocks = buffer.split(/\r?\n\r?\n/);
  const rest = final ? '' : blocks.pop();
  for (const block of blocks) {
    const data = block.split(/\r?\n/)
      .filter(line => line.startsWith('data:'))
      .map(line => line.slice(5).replace(/^ /, ''))
      .join('\n');
    if (!data) continue;
    try { events.push(JSON.parse(data)); } catch { events.push({ type: 'delta', text: data }); }
  }
  return { events, rest };
}
if (typeof window !== 'undefined') window.agentcoreParseSSE = agentcoreParseSSE;

// Create a global singleton so the same session is reused across your app
window.fixedAgentCoreClient = new FixedAgentCoreClient();
window.AGENTCORE_REASONS = AGENTCORE_REASONS;
