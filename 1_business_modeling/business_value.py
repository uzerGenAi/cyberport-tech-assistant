import streamlit as st

st.set_page_config(layout="wide")

st.title("Generative AI Value Model: Specialty Bakeries & Pastry Cafés — Multi-Agent Use Cases")

with st.sidebar:
    st.header("Controls & Assumptions")
    st.markdown("**➡️ Select a Use Case:**")
    use_case = st.selectbox("\n", [
        "Custom Cake Orders & Production Planning",
        "Customer Loyalty & Pastry Subscriptions",
        "Ingredient & Supply Chain Management"
    ])

    st.sidebar.markdown("---")

    if use_case == "Custom Cake Orders & Production Planning":
        col1, col2 = st.sidebar.columns(2)
        with col1:
            queries_per_day = st.number_input("Custom orders/day", value=120, min_value=1)
            agent_time = st.number_input("Human time (mins)", value=25.0, min_value=0.1)
            ai_time = st.number_input("AI time (mins)", value=4.0, min_value=0.1)
        with col2:
            agent_cost = st.number_input("Staff cost/hr (€)", value=22.0, min_value=0.0)
            ai_cost = st.number_input("AI cost/order (€)", value=0.05, min_value=0.0)
            ai_resolution = st.slider("AI handles (%)", 0, 100, 70)

        st.sidebar.markdown("---")
        col3, col4 = st.sidebar.columns(2)
        with col3:
            csat_improve = st.slider("CSAT improve (%)", 0, 20, 12)
            conversion_lift = st.slider("Conversion lift (%)", 0, 30, 18)
        with col4:
            personalization_uplift = st.slider("Personalisation (%)", 0, 10, 5)
            response_speed_uplift = st.slider("Response speed (%)", 0, 10, 4)
        recommendation_accuracy = st.slider("Recommendation accuracy (%)", 0, 10, 4)

    elif use_case == "Customer Loyalty & Pastry Subscriptions":
        col1, col2 = st.sidebar.columns(2)
        with col1:
            tickets_per_day = st.number_input("Interactions/day", value=800, min_value=1)
            agent_time = st.number_input("Human time (mins)", value=10.0, min_value=0.1)
            ai_time = st.number_input("AI time (mins)", value=2.0, min_value=0.1)
        with col2:
            agent_cost = st.number_input("Staff cost/hr (€)", value=20.0, min_value=0.0)
            ai_cost = st.number_input("AI cost/interaction (€)", value=0.03, min_value=0.0)
            ai_resolution = st.slider("AI handles (%)", 0, 100, 75)

        st.sidebar.markdown("---")
        col3, col4 = st.sidebar.columns(2)
        with col3:
            csat_improve = st.slider("CSAT improve (%)", 0, 20, 10)
            conversion_lift = st.slider("Subscription conversion (%)", 0, 30, 12)
        with col4:
            personalization_uplift = st.slider("Personalisation (%)", 0, 10, 5)
            response_speed_uplift = st.slider("Response speed (%)", 0, 10, 4)
        recommendation_accuracy = st.slider("Recommendation accuracy (%)", 0, 10, 3)

    elif use_case == "Ingredient & Supply Chain Management":
        col1, col2 = st.sidebar.columns(2)
        with col1:
            inventory_checks_per_month = st.number_input("Checks/month", value=300, min_value=1)
            agent_time = st.number_input("Human time (mins)", value=35.0, min_value=0.1)
            ai_time = st.number_input("AI time (mins)", value=6.0, min_value=0.1)
        with col2:
            agent_cost = st.number_input("Staff cost/hr (€)", value=28.0, min_value=0.0)
            ai_cost = st.number_input("AI cost/check (€)", value=0.08, min_value=0.0)
            ai_resolution = st.slider("AI automates (%)", 0, 100, 65)

        st.sidebar.markdown("---")
        col3, col4 = st.sidebar.columns(2)
        with col3:
            csat_improve = st.slider("Quality improve (%)", 0, 10, 4)
            conversion_lift = st.slider("Waste reduction (%)", 0, 30, 22)
        with col4:
            personalization_uplift = st.slider("Personalisation (%)", 0, 10, 2)
            response_speed_uplift = st.slider("Response speed (%)", 0, 10, 5)
        recommendation_accuracy = st.slider("Forecast accuracy (%)", 0, 10, 4)

# Business logic calculations
if use_case == "Custom Cake Orders & Production Planning":
    agent_hours = (queries_per_day * agent_time) / 60
    agent_cost_period = agent_hours * agent_cost
    ai_cost_period = queries_per_day * ai_cost
    savings = (agent_cost_period - ai_cost_period) * (ai_resolution / 100)
    annual_savings = savings * 365
elif use_case == "Customer Loyalty & Pastry Subscriptions":
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
if use_case == "Custom Cake Orders & Production Planning":
    st.markdown("### Use Case: Custom Cake Orders & Production Planning")
    st.write(
        "AI agents handle order intake, specification capture, scheduling, and customer updates — "
        "freeing pastry chefs to focus on crafting exceptional bakes."
    )
elif use_case == "Customer Loyalty & Pastry Subscriptions":
    st.markdown("### Use Case: Customer Loyalty & Pastry Subscriptions")
    st.write(
        "AI-driven loyalty and subscription management increases repeat visits, "
        "personalises recommendations, and resolves customer queries consistently."
    )
else:
    st.markdown("### Use Case: Ingredient & Supply Chain Management")
    st.write(
        "AI-powered inventory and supply chain management reduces ingredient waste, "
        "prevents stockouts of key items, and optimises daily production planning."
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
        if use_case == "Ingredient & Supply Chain Management":
            st.metric("Waste Reduction", f"{conversion_lift}%")
        elif use_case == "Customer Loyalty & Pastry Subscriptions":
            st.metric("Subscription Conv.", f"{conversion_lift}%")
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
