# Use an official Python runtime as a parent image
FROM python:3.11-slim

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file into the container at /app
COPY requirements.txt .

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code into the container
COPY . .

# Expose the port the app runs on
EXPOSE 8080

# Run the uvicorn server.
# The `main:app` refers to the `app` object in `main.py`.
# The host `0.0.0.0` is required for Cloud Run.
# The port `8080` is the default port for Cloud Run.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]