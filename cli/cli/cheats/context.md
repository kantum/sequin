// Create a context
sequin-cli context create dev --server-url=http://localhost:4000
sequin-cli context create prod --server-url=https://sequin.io

// List contexts
sequin-cli context ls

// Use a context
sequin-cli --context=dev stream ls