import streamlit as st

st.set_page_config(layout="wide")

st.title("Generative AI Value Model: Cyberport Tech Assistant — Multi-Agent Use Cases")
st.caption("Illustrative default assumptions for a mid-size online-first retailer, not Cyberport figures. Replace them with the client's own data.")

with st.sidebar:
    st.header("Controls & Assumptions")
    st.markdown("**➡️ Select a Use Case:**")
    use_case = st.selectbox("\n", [
        "Pre-sales Product Advice & Click & Collect",
        "After-sales: Order Status, Returns & Warranty",
        "Store Stock Visibility & Lost-sale Prevention"
    ])

    st.sidebar.markdown("---")

    if use_case == "Pre-sales Product Advice & Click & Collect":
        col1, col2 = st.sidebar.columns(2)
        with col1:
            queries_per_day = st.number_input("Advice contacts/day", value=1500, min_value=1)
            agent_time = st.number_input("Human time (mins)", value=8.0, min_value=0.1)
            ai_time = st.number_input("AI time (mins)", value=1.5, min_value=0.1)
        with col2:
            agent_cost = st.number_input("Staff cost/hr (€)", value=30.0, min_value=0.0)
            ai_cost = st.number_input("AI cost/contact (€)", value=0.05, min_value=0.0)
            ai_resolution = st.slider("AI handles (%)", 0, 100, 40)

        st.sidebar.markdown("---")
        col3, col4 = st.sidebar.columns(2)
        with col3:
            csat_improve = st.slider("CSAT improve (%)", 0, 20, 10)
            conversion_lift = st.slider("Conversion lift (%)", 0, 30, 8)
        with col4:
            personalization_uplift = st.slider("Personalisation (%)", 0, 10, 5)
            response_speed_uplift = st.slider("Response speed (%)", 0, 10, 6)
        recommendation_accuracy = st.slider("Recommendation accuracy (%)", 0, 10, 5)

    elif use_case == "After-sales: Order Status, Returns & Warranty":
        col1, col2 = st.sidebar.columns(2)
        with col1:
            tickets_per_day = st.number_input("Service contacts/day", value=2500, min_value=1)
            agent_time = st.number_input("Human time (mins)", value=6.0, min_value=0.1)
            ai_time = st.number_input("AI time (mins)", value=1.0, min_value=0.1)
        with col2:
            agent_cost = st.number_input("Staff cost/hr (€)", value=28.0, min_value=0.0)
            ai_cost = st.number_input("AI cost/contact (€)", value=0.03, min_value=0.0)
            ai_resolution = st.slider("AI handles (%)", 0, 100, 55)

        st.sidebar.markdown("---")
        col3, col4 = st.sidebar.columns(2)
        with col3:
            csat_improve = st.slider("CSAT improve (%)", 0, 20, 12)
            conversion_lift = st.slider("Return-rate reduction (%)", 0, 30, 10)
        with col4:
            personalization_uplift = st.slider("Personalisation (%)", 0, 10, 5)
            response_speed_uplift = st.slider("Response speed (%)", 0, 10, 8)
        recommendation_accuracy = st.slider("Answer accuracy (%)", 0, 10, 4)

    elif use_case == "Store Stock Visibility & Lost-sale Prevention":
        col1, col2 = st.sidebar.columns(2)
        with col1:
            inventory_checks_per_month = st.number_input("Stock enquiries/month", value=12000, min_value=1)
            agent_time = st.number_input("Human time (mins)", value=4.0, min_value=0.1)
            ai_time = st.number_input("AI time (mins)", value=0.5, min_value=0.1)
        with col2:
            agent_cost = st.number_input("Staff cost/hr (€)", value=25.0, min_value=0.0)
            ai_cost = st.number_input("AI cost/enquiry (€)", value=0.02, min_value=0.0)
            ai_resolution = st.slider("AI automates (%)", 0, 100, 70)

        st.sidebar.markdown("---")
        col3, col4 = st.sidebar.columns(2)
        with col3:
            csat_improve = st.slider("CSAT improve (%)", 0, 10, 4)
            conversion_lift = st.slider("Lost-sale reduction (%)", 0, 30, 6)
        with col4:
            personalization_uplift = st.slider("Personalisation (%)", 0, 10, 2)
            response_speed_uplift = st.slider("Response speed (%)", 0, 10, 5)
        recommendation_accuracy = st.slider("Stock answer accuracy (%)", 0, 10, 4)

# Business logic calculations
if use_case == "Pre-sales Product Advice & Click & Collect":
    agent_hours = (queries_per_day * agent_time) / 60
    agent_cost_period = agent_hours * agent_cost
    ai_cost_period = queries_per_day * ai_cost
    savings = (agent_cost_period - ai_cost_period) * (ai_resolution / 100)
    annual_savings = savings * 365
elif use_case == "After-sales: Order Status, Returns & Warranty":
    agent_hours = (tickets_per_day * agent_time) / 60
    agent_cost_period = agent_hours * agent_cost
    ai_cost_period = tickets_per_day * ai_cost
    savings = (agent_cost_period - ai_cost_period) * (ai_resolution / 100)
    annual_savings = savings * 365
else:
    agent_hours = (inventory_checks_per_month * agent_time) / 60
    agent_cost_period = agent_hours * agent_cost
    ai_cost_period = inventory_checks_per_month * ai_cost
    savings = (agent_cost_period - ai_cost_period) * (ai_resolution / 100)
    annual_savings = savings * 12

total_cx_gain = csat_improve + personalization_uplift + response_speed_uplift + recommendation_accuracy

# Main panel
if use_case == "Pre-sales Product Advice & Click & Collect":
    st.markdown("### Use Case: Pre-sales Product Advice & Click & Collect")
    st.write(
        "AI agents compare specs, recommend the right smartphone or laptop, quote exact prices and "
        "place click & collect orders, so store and hotline staff can focus on complex advice."
    )
elif use_case == "After-sales: Order Status, Returns & Warranty":
    st.markdown("### Use Case: After-sales: Order Status, Returns & Warranty")
    st.write(
        "AI agents answer order status, delivery, return, warranty and financing questions 24/7 "
        "from live order data and policy documents, and hand complex cases to the hotline."
    )
else:
    st.markdown("### Use Case: Store Stock Visibility & Lost-sale Prevention")
    st.write(
        "AI agents tell customers which store has a product in stock and when it is open, "
        "turning online browsing into store visits and reducing lost sales."
    )

col1, col2, col3 = st.columns(3)

with col1:
    st.subheader("✅ Customer Experience")
    metric_cols1, metric_cols2 = st.columns(2)
    with metric_cols1:
        st.metric("CSAT Uplift", f"{csat_improve}%")
        st.metric("Personalisation", f"{personalization_uplift}%")
    with metric_cols2:
        st.metric("Faster Response", f"{response_speed_uplift}%")
        st.metric("Better Recommendations", f"{recommendation_accuracy}%")
    st.metric("Total CX Gain", f"{total_cx_gain}%")

with col2:
    st.subheader("🛠 Staff Productivity")
    metric_cols3, metric_cols4 = st.columns(2)
    with metric_cols3:
        st.metric("Staff Hours", f"{agent_hours:,.1f}")
        st.metric("Staff Cost", f"€{agent_cost_period:,.0f}")
    with metric_cols4:
        st.metric("AI Agent Cost", f"€{ai_cost_period:,.2f}")
        st.metric("AI Handling Rate", f"{ai_resolution}%")

with col3:
    st.subheader("💰 Business Operations")
    metric_cols5, metric_cols6 = st.columns(2)
    with metric_cols5:
        st.metric("Savings (Period)", f"€{savings:,.0f}")
        st.metric("Annual Savings", f"€{annual_savings:,.0f}")
    with metric_cols6:
        if use_case == "Store Stock Visibility & Lost-sale Prevention":
            st.metric("Lost-sale Reduction", f"{conversion_lift}%")
        elif use_case == "After-sales: Order Status, Returns & Warranty":
            st.metric("Return-rate Reduction", f"{conversion_lift}%")
        else:
            st.metric("Conversion Lift", f"{conversion_lift}%")
        time_saved = ((agent_time - ai_time) * ai_resolution / 100)
        st.metric("Time Saved Per Interaction", f"{time_saved:.1f} mins")

st.markdown("---")
chart_col1, chart_col2 = st.columns(2)

with chart_col1:
    st.subheader("Cost Comparison (€)")
    chart_data = {
        "Human Process": agent_cost_period,
        "AI-Assisted Process": agent_cost_period * (1 - ai_resolution / 100) + ai_cost_period
    }
    st.bar_chart(chart_data)

with chart_col2:
    st.subheader("Customer Experience Impact")
    cx_data = {
        "Baseline": 100,
        "With AI": 100 + total_cx_gain
    }
    st.bar_chart(cx_data)
