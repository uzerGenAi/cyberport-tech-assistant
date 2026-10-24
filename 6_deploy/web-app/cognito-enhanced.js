// Enhanced Cognito Authentication with Identity Pool Support
// This script handles authentication with AWS Cognito User Pool and Identity Pool
// for direct AWS API access with temporary credentials

document.addEventListener('DOMContentLoaded', function() {
  // Check if user is already authenticated
  checkAuthentication();

  // Handle login form submission
  const loginForm = document.getElementById('loginForm');
  if (loginForm) {
    loginForm.addEventListener('submit', function(e) {
      e.preventDefault();
      const username = document.getElementById('username').value;
      const password = document.getElementById('password').value;
      authenticateUser(username, password);
    });
  }
});

// Global variables for AWS configuration
let cognitoConfig = null;
let awsCredentials = null;

// Build an Error that carries a machine-readable `reason` so callers can explain
// *why* something failed instead of guessing. Keep these codes in sync with the
// FAILURE_COPY table in script-enhanced.js.
//   not-signed-in       — nothing stored; the user never authenticated on this tab
//   credentials-expired — had credentials/token, but they are no longer usable
//   not-configured      — deployment config missing or incomplete
function authError(message, reason) {
  const err = new Error(message);
  err.reason = reason;
  return err;
}

// Preview mode lets a visitor browse the page's local sample data without live
// AWS credentials. It is explicit and un-sticky: `?preview=1` turns it on for
// the tab, `?preview=0` clears it. Without a query parameter the stored value
// decides.
//
// The feature used to be called "demo". The legacy `?demo=1` parameter and the
// legacy `demoMode` storage key are still honoured so old bookmarks and
// in-flight sessions keep working, but everything written going forward uses
// the `preview` names.
const PREVIEW_KEY = 'previewMode';
const LEGACY_PREVIEW_KEY = 'demoMode';

function readPreviewParam() {
  const params = new URLSearchParams(window.location.search);
  // New name wins; fall back to the legacy one.
  return params.get('preview') ?? params.get('demo');
}

function isPreviewMode() {
  const requested = readPreviewParam();
  if (requested === '1') {
    setPreviewMode(true);
    return true;
  }
  if (requested === '0') {
    setPreviewMode(false);
    return false;
  }
  return sessionStorage.getItem(PREVIEW_KEY) === '1'
      || sessionStorage.getItem(LEGACY_PREVIEW_KEY) === '1';
}

function setPreviewMode(enabled) {
  if (enabled) {
    sessionStorage.setItem(PREVIEW_KEY, '1');
  } else {
    sessionStorage.removeItem(PREVIEW_KEY);
    sessionStorage.removeItem(LEGACY_PREVIEW_KEY);
  }
}

// Function to load Cognito configuration
async function loadCognitoConfig() {
  try {
    const response = await fetch('cognito-config.json');
    if (!response.ok) {
      throw authError(`cognito-config.json returned HTTP ${response.status}`, 'not-configured');
    }
    cognitoConfig = await response.json();
    if (!cognitoConfig || !cognitoConfig.UserPoolId || !cognitoConfig.ClientId || !cognitoConfig.IdentityPoolId) {
      throw authError('cognito-config.json is missing UserPoolId, ClientId or IdentityPoolId', 'not-configured');
    }
    console.log('Cognito configuration loaded:', cognitoConfig);
    return cognitoConfig;
  } catch (error) {
    console.error('Error loading Cognito configuration:', error);
    if (!error.reason) error.reason = 'not-configured';
    throw error;
  }
}

// Function to check if user is authenticated
async function checkAuthentication() {
  // If we're already on the login page, don't redirect
  function isLoginPage() {
    const p = window.location.pathname.toLowerCase();
    return p.endsWith('login.html') || p.endsWith('/login');
  }

  if (isLoginPage()) return;

  if (isPreviewMode()) {
    sessionStorage.removeItem('redirectedToLogin');
    console.log('Preview mode enabled; skipping auth redirect');
    return;
  }
  
  // Check if we have valid AWS credentials
  const storedCredentials = sessionStorage.getItem('awsCredentials');
  if (!storedCredentials) {
    // No credentials found, redirect to login page
    if (!sessionStorage.getItem('redirectedToLogin')) {
      sessionStorage.setItem('redirectedToLogin', '1');
      window.location.replace('login.html');
    }
    return;
  }
  
  try {
    const credentials = JSON.parse(storedCredentials);
    const now = new Date().getTime();
    
    // Check if credentials are expired (with 5 minute buffer)
    if (credentials.expiration && now >= (credentials.expiration - 300000)) {
      console.log('AWS credentials expired, redirecting to login');
      sessionStorage.removeItem('awsCredentials');
      sessionStorage.removeItem('idToken');
      window.location.href = 'login.html';
      return;
    }
    
    // Credentials are valid, set them globally
    awsCredentials = credentials;
    sessionStorage.removeItem('redirectedToLogin');
    console.log('Valid AWS credentials found');
    
  } catch (error) {
    console.error('Error parsing stored credentials:', error);
    sessionStorage.removeItem('awsCredentials');
    window.location.href = 'login.html';
  }
}

// Function to authenticate user with Cognito User Pool
async function authenticateUser(username, password) {
  try {
    // Load configuration if not already loaded
    if (!cognitoConfig) {
      await loadCognitoConfig();
    }
    
    // Initialize the Amazon Cognito credentials provider
    const authenticationData = {
      Username: username,
      Password: password
    };
    
    const poolData = {
      UserPoolId: cognitoConfig.UserPoolId,
      ClientId: cognitoConfig.ClientId
    };
    
    const userPool = new AmazonCognitoIdentity.CognitoUserPool(poolData);
    
    const userData = {
      Username: username,
      Pool: userPool
    };
    
    const cognitoUser = new AmazonCognitoIdentity.CognitoUser(userData);
    
    // Set authentication parameters to use USER_PASSWORD_AUTH flow
    const authenticationDetails = new AmazonCognitoIdentity.AuthenticationDetails(authenticationData);
    
    // Authenticate user with explicit auth flow
    cognitoUser.setAuthenticationFlowType('USER_PASSWORD_AUTH');
    
    cognitoUser.authenticateUser(authenticationDetails, {
      onSuccess: async function(result) {
        try {
          // Store ID token in session storage
          const idToken = result.getIdToken().getJwtToken();
          sessionStorage.setItem('idToken', idToken);
          
          // Extract user information from the JWT token
          const tokenPayload = JSON.parse(atob(idToken.split('.')[1]));
          const userId = tokenPayload.sub;
          const extractedUsername = tokenPayload['cognito:username'] || tokenPayload.username || username;
          
          // Store user information
          sessionStorage.setItem('userId', userId);
          sessionStorage.setItem('username', extractedUsername);
          
          console.log('User authenticated with User Pool:', { userId, username: extractedUsername });
          
          // Now get AWS credentials from Identity Pool
          await getAWSCredentials(idToken);
          
          // Redirect to main page
          sessionStorage.removeItem('redirectedToLogin');
          window.location.replace('index.html');
          
        } catch (error) {
          console.error('Error in authentication success handler:', error);
          showError('Authentication succeeded but failed to get AWS credentials. Please try again.');
        }
      },
      onFailure: function(err) {
        console.error('Authentication error:', err);
        showError(err.message || 'Failed to authenticate. Please check your credentials.');
      }
    });
    
  } catch (error) {
    console.error('Error in authentication process:', error);
    showError('Authentication service unavailable. Please try again later.');
  }
}

// --- Password reset (forgot password) flow ---
// Uses Cognito's forgotPassword()/confirmPassword() APIs. The first step emails
// (or SMS-es) a reset code to the user; the second step consumes that code plus
// a new password. Both resolve/reject through Promises so the UI can await them.

// Build a CognitoUser for the given username using the configured pool.
async function buildCognitoUser(username) {
  if (!cognitoConfig) {
    await loadCognitoConfig();
  }
  const userPool = new AmazonCognitoIdentity.CognitoUserPool({
    UserPoolId: cognitoConfig.UserPoolId,
    ClientId: cognitoConfig.ClientId
  });
  return new AmazonCognitoIdentity.CognitoUser({ Username: username, Pool: userPool });
}

// Step 1: ask Cognito to send a password reset code to the user.
function requestPasswordReset(username) {
  return buildCognitoUser(username).then(cognitoUser => new Promise((resolve, reject) => {
    cognitoUser.forgotPassword({
      onSuccess: function(data) {
        console.log('Password reset code sent:', data);
        resolve(data);
      },
      onFailure: function(err) {
        console.error('forgotPassword error:', err);
        reject(err);
      },
      // Fires when a verified delivery medium exists and the code was sent.
      inputVerificationCode: function(data) {
        console.log('Password reset code delivered:', data);
        resolve(data);
      }
    });
  }));
}

// Step 2: confirm the reset with the emailed code and a new password.
function confirmPasswordReset(username, code, newPassword) {
  return buildCognitoUser(username).then(cognitoUser => new Promise((resolve, reject) => {
    cognitoUser.confirmPassword(code, newPassword, {
      onSuccess: function() {
        console.log('Password reset confirmed');
        resolve();
      },
      onFailure: function(err) {
        console.error('confirmPassword error:', err);
        reject(err);
      }
    });
  }));
}

// Function to get AWS credentials from Identity Pool
async function getAWSCredentials(idToken) {
  try {
    console.log('Getting AWS credentials from Identity Pool...');
    console.log('Identity Pool ID:', cognitoConfig.IdentityPoolId);
    console.log('User Pool ID:', cognitoConfig.UserPoolId);
    console.log('Region:', cognitoConfig.Region);
    
    // Configure AWS SDK
    AWS.config.region = cognitoConfig.Region;
    
    // Create the login key for the Identity Pool
    const loginKey = `cognito-idp.${cognitoConfig.Region}.amazonaws.com/${cognitoConfig.UserPoolId}`;
    console.log('Login key:', loginKey);
    
    // Create credentials object for Identity Pool
    const cognitoIdentityCredentials = new AWS.CognitoIdentityCredentials({
      IdentityPoolId: cognitoConfig.IdentityPoolId,
      Logins: {
        [loginKey]: idToken
      }
    });
    
    console.log('Created CognitoIdentityCredentials object');
    
    // Get credentials
    await new Promise((resolve, reject) => {
      cognitoIdentityCredentials.get((err) => {
        if (err) {
          console.error('Error getting AWS credentials:', err);
          console.error('Error code:', err.code);
          console.error('Error message:', err.message);
          console.error('Error stack:', err.stack);
          reject(err);
        } else {
          console.log('Successfully obtained credentials from Identity Pool');
          resolve();
        }
      });
    });
    
    // Store credentials with expiration time
    const credentials = {
      accessKeyId: cognitoIdentityCredentials.accessKeyId,
      secretAccessKey: cognitoIdentityCredentials.secretAccessKey,
      sessionToken: cognitoIdentityCredentials.sessionToken,
      identityId: cognitoIdentityCredentials.identityId,
      expiration: cognitoIdentityCredentials.expireTime ? cognitoIdentityCredentials.expireTime.getTime() : null
    };
    
    // Store credentials in session storage
    sessionStorage.setItem('awsCredentials', JSON.stringify(credentials));
    awsCredentials = credentials;
    
    console.log('AWS credentials obtained successfully');
    console.log('Identity ID:', credentials.identityId);
    console.log('Access Key ID:', credentials.accessKeyId ? credentials.accessKeyId.substring(0, 10) + '...' : 'undefined');
    console.log('Credentials expire at:', credentials.expiration ? new Date(credentials.expiration) : 'No expiration');
    
  } catch (error) {
    console.error('Failed to get AWS credentials:', error);
    console.error('Error details:', {
      name: error.name,
      message: error.message,
      code: error.code,
      statusCode: error.statusCode
    });
    throw new Error('Failed to get AWS credentials: ' + error.message);
  }
}

// Function to get current AWS credentials (refresh if needed)
async function getCurrentAWSCredentials() {
  if (!awsCredentials) {
    const storedCredentials = sessionStorage.getItem('awsCredentials');
    if (storedCredentials) {
      try {
        awsCredentials = JSON.parse(storedCredentials);
      } catch (parseError) {
        sessionStorage.removeItem('awsCredentials');
        throw authError('Stored AWS credentials were unreadable. Please sign in again.', 'credentials-expired');
      }
    } else {
      // Nothing stored at all: this tab never completed a sign-in.
      throw authError('Not signed in — no AWS credentials in this session.', 'not-signed-in');
    }
  }
  
  // Check if credentials are expired (with 5 minute buffer)
  const now = new Date().getTime();
  if (awsCredentials.expiration && now >= (awsCredentials.expiration - 300000)) {
    console.log('AWS credentials expired, attempting refresh...');
    
    const idToken = sessionStorage.getItem('idToken');
    if (!idToken) {
      throw authError('Session expired and no ID token is available to refresh it.', 'credentials-expired');
    }
    
    if (!cognitoConfig) {
      await loadCognitoConfig();
    }
    
    try {
      await getAWSCredentials(idToken);
    } catch (refreshError) {
      // The ID token itself has expired or been revoked.
      throw authError(`Session expired and could not be refreshed: ${refreshError.message}`, 'credentials-expired');
    }
  }
  
  return awsCredentials;
}

// Function to create AWS service clients with current credentials
async function createAWSServiceClient(serviceName, options = {}) {
  const credentials = await getCurrentAWSCredentials();
  
  const serviceOptions = {
    region: cognitoConfig.Region,
    accessKeyId: credentials.accessKeyId,
    secretAccessKey: credentials.secretAccessKey,
    sessionToken: credentials.sessionToken,
    ...options
  };
  
  return new AWS[serviceName](serviceOptions);
}

// Function to show error messages
function showError(message) {
  const errorMessage = document.getElementById('errorMessage');
  if (errorMessage) {
    errorMessage.textContent = message;
    errorMessage.style.display = 'block';
  } else {
    alert(message);
  }
}

// Function to sign out user.
// Clears every piece of per-user state, including preview mode and the agent
// session id — otherwise the next user inherits the previous conversation.
function signOut() {
  [
    'idToken',
    'awsCredentials',
    'userId',
    'username',
    'selectedStore',
    'previewMode',
    'demoMode',
    'redirectedToLogin',
  ].forEach(key => sessionStorage.removeItem(key));
  
  try { localStorage.removeItem('chatbot_session_id'); } catch { /* ignore */ }
  
  // Clear global variables
  awsCredentials = null;
  
  // Redirect to login page
  window.location.replace('login.html');
}

// Export functions for use in other scripts
window.CognitoAuth = {
  getCurrentAWSCredentials,
  createAWSServiceClient,
  signOut,
  loadCognitoConfig,
  isPreviewMode,
  setPreviewMode,
  requestPasswordReset,
  confirmPasswordReset,
  getConfig: () => cognitoConfig,
};
