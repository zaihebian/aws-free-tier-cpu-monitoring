import requests
import pandas as pd
import streamlit as st

# ---------------------------
# CONFIGURATION
# ---------------------------
API_URL = "https://08ihp8cwkd.execute-api.us-east-1.amazonaws.com/query"

st.set_page_config(page_title="Athena Metrics Dashboard", layout="wide")
st.title("EC2 Metrics Dashboard")

# ---------------------------
# SIDEBAR QUERY INPUT
# ---------------------------
st.sidebar.header("Query Settings")
default_query = "SELECT * FROM cpu_metrics.ec2_metrics_typed ORDER BY ts DESC LIMIT 100;"
query = st.sidebar.text_area("Enter SQL query:", default_query, height=150)

# ---------------------------
# CALL YOUR API
# ---------------------------
if st.sidebar.button("Run Query"):
    try:
        response = requests.post(API_URL, json={"query": query})
        response.raise_for_status()
        data = response.json()

        # Handle nested response
        if isinstance(data, dict) and "data" in data:
            data = data["data"]

        # Convert to DataFrame
        df = pd.DataFrame(data)
        if df.empty:
            st.warning("Query executed successfully but returned no results.")
        else:
            # ---------------------------
            # FIX DATA TYPES
            # ---------------------------
            for col in ["cpu_percent", "network_in_bytes", "network_out_bytes"]:
                if col in df.columns:
                    df[col] = pd.to_numeric(df[col], errors="coerce")

            # Convert timestamps
            if "ts" in df.columns:
                df["ts"] = pd.to_datetime(df["ts"], errors="coerce")

            st.success("Query executed successfully!")
            st.dataframe(df)

            # ---------------------------
            # VISUALIZATIONS
            # ---------------------------
            st.subheader("CPU Utilization Over Time")
            if "ts" in df.columns and "cpu_percent" in df.columns:
                st.line_chart(df.set_index("ts")["cpu_percent"])

            st.subheader("Network In / Out Over Time")
            if "ts" in df.columns and "network_in_bytes" in df.columns and "network_out_bytes" in df.columns:
                st.line_chart(df.set_index("ts")[["network_in_bytes", "network_out_bytes"]])

            st.subheader("Correlation Heatmap")
            numeric_df = df.select_dtypes(include=["number"])
            if not numeric_df.empty:
                st.bar_chart(numeric_df.corr())

    except Exception as e:
        st.error(f"Error: {e}")
