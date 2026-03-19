# Private Endpoint Limit Helper — Azure Workbook

## Overview

This folder contains an Azure Monitor Workbook designed to help customers identify and manage **Private Endpoint (PE) limits** across their Azure tenant. It provides comprehensive visibility into PE consumption per VNET, hub-spoke peered groups, resource types, and subscriptions.

## Files

| File | Description |
|---|---|
| `Private-Endpoint-Limit-Helper.workbook` | Main workbook — **English** version |
| `Private-Endpoint-Limit-Helper-PTBR.workbook` | Main workbook — **Português do Brasil** version |

## Azure Limits Covered

| Scope | Limit |
|---|---|
| Private Endpoints per VNET | **1,000** |
| Private Endpoints across peered VNETs (hub-spoke) | **4,000** |
| Private Endpoints per subscription | **64,000** |

> **Reference**: [Azure subscription and service limits – Private Link limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#private-link-limits)

## Workbook Tabs

### 📊 Overview
- Summary tiles: Total PEs, VNETs with PEs, At-Risk VNETs, Max PEs in a single VNET
- Grid ranking all VNETs by PE count with color-coded status (OK / Warning / Critical)
- Top 20 VNETs bar chart

### 🌐 Hub-Spoke Analysis
- Discovers VNET peering relationships automatically
- Shows each VNET's PE count against the correct effective limit (1,000 for standalone, 4,000 for peered)
- Full peering relationship table

### 🔍 VNET Detail
- Dropdown to select a specific VNET
- 4 tiles: PE Count, % Used, Remaining Capacity, Status
- Pie charts for subnet and resource type distribution
- Full detail grid with connection status, target resources, and direct links

### 📦 By Resource Type
- Bar chart of PE count per resource type
- Summary grid with distinct VNET, subnet, and subscription counts per type
- **Drill-down**: Click a resource type row to load filtered detail grid (avoids ARG 1,000-row limit)

### 📋 By Subscription
- PE count per subscription with % of 64K limit
- Hierarchical grid by Subscription > VNET
- Pie chart of PE distribution across subscriptions

## Deployment

### Option 1 — Azure Portal (Import)
1. Open **Azure Monitor** > **Workbooks**
2. Click **+ New** > **Advanced Editor** (code icon `</>` in toolbar)
3. Paste the `.workbook` JSON content
4. Click **Apply** then **Save**

### Option 2 — ARM Template
Deploy as part of an ARM/Bicep template using `Microsoft.Insights/workbooks` resource type, referencing the JSON as the `serializedData` property.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| Subscriptions | All | Scope the workbook to specific subscriptions |
| Warning Threshold (%) | 70 | VNETs above this % are flagged as ⚠️ Warning |
| Critical Threshold (%) | 90 | VNETs above this % are flagged as 🔴 Critical |

## Technical Notes

- All queries use **Azure Resource Graph (ARG)** — no Log Analytics workspace required
- PE-to-VNET mapping is derived from `properties.subnet.id`
- Target resource type is extracted from `privateLinkServiceConnections[].privateLinkServiceId`
- The By Resource Type tab uses a **summary-first + drill-down** pattern to work around ARG's 1,000-row query limit
- Hub-Spoke analysis uses `leftouter` join instead of `fullouter` to avoid ARG's limitation with string comparison operators

## Language Versions

- **English**: `Private-Endpoint-Limit-Helper.workbook`
- **Português do Brasil**: `Private-Endpoint-Limit-Helper-PTBR.workbook` — All UI text, labels, descriptions, and status messages translated to Brazilian Portuguese. KQL queries and Azure API field names remain unchanged.
