// This script handles authentication with AWS Cognito
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

// Function to check if user is authenticated
function checkAuthentication() {
  // If we're already on the login page, don't redirect
  if (window.location.pathname.endsWith('login.html')) {
    return;
  }
  
  // Check if we have a valid session token
  const idToken = sessionStorage.getItem('idToken');
  if (!idToken) {
    // No token found, redirect to login page
    window.location.href = 'login.html';
  }
}

// Function to authenticate user with Cognito
function authenticateUser(username, password) {
  // First, we need to fetch the Cognito User Pool details
  fetch('cognito-config.json')
    .then(response => response.json())
    .then(config => {
      // Initialize the Amazon Cognito credentials provider
      const authenticationData = {
        Username: username,
        Password: password
      };
      
      const poolData = {
        UserPoolId: config.UserPoolId,
        ClientId: config.ClientId
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
        onSuccess: function(result) {
          // Store tokens in session storage
          const idToken = result.getIdToken().getJwtToken();
          sessionStorage.setItem('idToken', idToken);
          
          // Extract user information from the JWT token
          try {
            const tokenPayload = JSON.parse(atob(idToken.split('.')[1]));
            const userId = tokenPayload.sub; // 'sub' is the unique user identifier in Cognito
            const extractedUsername = tokenPayload['cognito:username'] || tokenPayload.username || username;
            
            // Store user information for use by the agents
            sessionStorage.setItem('userId', userId);
            sessionStorage.setItem('username', extractedUsername);
            
            console.log('User authenticated:', { userId, username: extractedUsername });
          } catch (error) {
            console.error('Error parsing JWT token:', error);
          }
          
          // Redirect to main page
          window.location.href = 'index.html';
        },
        onFailure: function(err) {
          // Display error message
          const errorMessage = document.getElementById('errorMessage');
          errorMessage.textContent = err.message || 'Failed to authenticate. Please check your credentials.';
          errorMessage.style.display = 'block';
          console.error('Authentication error:', err);
        }
      });
    })
    .catch(error => {
      console.error('Error fetching Cognito configuration:', error);
      const errorMessage = document.getElementById('errorMessage');
      errorMessage.textContent = 'Authentication service unavailable. Please try again later.';
      errorMessage.style.display = 'block';
    });
}
