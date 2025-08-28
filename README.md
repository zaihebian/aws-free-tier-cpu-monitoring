# **AWS EC2 Monitoring & Visualization Dashboard**

This project implements a **serverless EC2 monitoring solution** using **AWS Lambda, S3, Athena, API Gateway, and Streamlit**.  
It collects EC2 metrics from **CloudWatch**, stores them in **S3** as CSV files, queries historical data via **Athena**, exposes a **REST API**, and visualizes everything in an **interactive dashboard**.

---

## **📌 Features**
- **Automated EC2 metrics collection** using Lambda.
- Stores CSVs in **S3**, partitioned by date.
- Queries processed data via **Athena**.
- Exposes query results through a **REST API Gateway** endpoint.
- **Streamlit dashboard** for interactive exploration and visualization.
- Fully deployed using **Terraform** for Infrastructure-as-Code.

---

## **📐 Architecture**

```plaintext
           +----------------+
           |    EC2         |
           +--------+-------+
                    |
                    v
           +----------------+
           | CloudWatch     |
           +----------------+
                    |
                    v
       (1) Lambda: analyze_metrics.py
                    |
                    v
           +----------------+
           | S3 CSV Storage |
           +----------------+
                    |
                    v
           +----------------+
           | Athena Query   |
           +----------------+
                    |
          +------------------+
          | API Gateway (REST)|
          +------------------+
                    |
                    v
           +----------------+
           | Streamlit App  |
           +----------------+
```

## 📄 Code Overview
---

### **1. analyze_metrics.py** — *Collect metrics & store CSV*
- Fetches **CPUUtilization**, **NetworkIn**, **NetworkOut** from **CloudWatch**.
- Generates **daily CSVs** in S3:
  ```bash
  s3://<bucket>/ec2-metrics/YYYY/MM/DD/instance-<id>.csv
### 🔧 Environment Variables

| Variable         | Description                          | Example Value                       |
|------------------|--------------------------------------|-------------------------------------|
| `BUCKET_NAME`    | S3 bucket where CSV files are stored | `damao-cpu-metrics`                |
| `INSTANCE_ID`    | The monitored EC2 instance ID        | `i-04ab89cf6ac14379e`              |
| `PERIOD_SECONDS` | Metric resolution in seconds         | `300` *(5-minute basic monitoring)* |

---

### **2. `lambda_function.py`** — *Athena Query API*
- Executes Athena queries against the processed metrics.
- Stores the generated Athena CSV into **S3**.
- Returns query results as **JSON** for API consumption.
- Integrated with **API Gateway**.

---

### **3. `dashboard.py`** — *Interactive Visualization*
- Built using **Streamlit**.
- Sends custom **SQL queries** via the **API Gateway endpoint**.
- Displays metrics in **interactive tables** and **visualizations**:
  - **CPU Utilization over time**
  - **Network In/Out trends**
  - **Correlation heatmaps**

---

### **4. Terraform Infrastructure (`main.tf`, `athena_api.tf`)**
- Provisions all **AWS resources**:
  - **EC2 instance**
  - **S3 bucket** for CSV storage
  - **Two Lambda functions**:
    - **analyze_metrics** → Collect & store CSVs.
    - **athena_query** → Query via Athena + API.
  - **API Gateway endpoint**
  - **Athena permissions & roles**
- Enables **Infrastructure as Code** and fully reproducible deployments.

---

## 🛠️ Deployment Guide

### **1. Deploy Infrastructure**

```bash
cd terraform
terraform init
terraform apply
````
### **2. Deploy Infrastructure**

```bash
pip install -r requirements.txt
streamlit run dashboard.py
```
## 📡 API Usage

### Endpoint

```bash
POST https://<api-id>.execute-api.<region>.amazonaws.com/query
```
### Example Request

``` bash
curl -X POST \
-H "Content-Type: application/json" \
-d '{"query": "SELECT * FROM cpu_metrics.ec2_metrics_typed LIMIT 10;"}' \
https://<endpoint>/query
```
### Example Response

``` json
{
  "data": [
    {
      "ts": "2025-08-27T15:00:00Z",
      "cpu_percent": 3.4,
      "network_in_bytes": 2300,
      "network_out_bytes": 1042
    }
  ],
  "csv_url": "s3://damao-cpu-metrics/athena-query-results/latest.csv"
}
```
## 📊 Example Dashboard Visualizations
- **CPU Utilization Over Time** → Line chart
- **Network In / Out Over Time** → Multi-series line chart
- **Correlation Heatmap** → Visualize metric relationships

> 💡 *demo* deployed on Streamlit
[Watch the demo video](https://raw.githubusercontent.com/zaihebian/aws-free-tier-cpu-monitoring/main/AWS.mp4)






