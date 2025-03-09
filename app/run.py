#!/usr/bin/env python3
import os
import sys
import subprocess

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8501"))
    host = "0.0.0.0"
    
    print(f"Starting Streamlit app on {host}:{port}...")
    
    # Execute streamlit directly without using subprocess
    # This replaces the current process with the streamlit process
    os.execvp("streamlit", [
        "streamlit", 
        "run", 
        "app.py", 
        "--server.port", str(port), 
        "--server.address", host,
        "--server.enableCORS", "false",
        "--server.enableXsrfProtection", "false"
    ])