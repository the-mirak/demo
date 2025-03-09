import streamlit as st
import pandas as pd
import numpy as np

# Set page title and configuration
st.set_page_config(
    page_title="AWS EKS Demo App",
    page_icon="🚀",
    layout="wide"
)

# App header
st.title("🚀 Streamlit App on AWS EKS Demo with CI/CD v1")
st.markdown("### Deployed with Kaniko on Amazon EKS")

# Sidebar
st.sidebar.header("Demo Controls")
sample_size = st.sidebar.slider("Sample Size", 10, 100, 50)
chart_type = st.sidebar.selectbox("Chart Type", ["Line", "Bar", "Area"])

# Generate sample data
def generate_data(samples):
    dates = pd.date_range(start="2023-01-01", periods=samples)
    values = np.random.normal(0, 1, size=samples).cumsum()
    return pd.DataFrame({"date": dates, "value": values})

data = generate_data(sample_size)

# Display data and visualization
st.subheader("Generated Sample Data")
st.dataframe(data)

st.subheader("Data Visualization")
col1, col2 = st.columns(2)

with col1:
    if chart_type == "Line":
        st.line_chart(data.set_index("date"))
    elif chart_type == "Bar":
        st.bar_chart(data.set_index("date"))
    else:
        st.area_chart(data.set_index("date"))

with col2:
    st.metric("Number of Samples", sample_size)
    st.metric("Final Value", round(data["value"].iloc[-1], 2))
    st.metric("Value Change", round(data["value"].iloc[-1] - data["value"].iloc[0], 2))

# Footer
st.divider()
st.markdown("**Deployment Info**")
st.markdown("* 📦 Built with Kaniko")
st.markdown("* 🐳 Image stored in Amazon ECR")
st.markdown("* ☸️ Running on Amazon EKS")