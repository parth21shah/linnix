# Test the Linnix quickstart setup
# This script verifies that all services are working correctly

function test_quickstart() {
    echo "🧪 Testing Linnix quickstart setup..."
    
    # Test 1: Check if containers are running
    echo "✓ Checking Docker containers..."
    docker-compose ps | grep -E "(cognitod|llama-server|dashboard)" || {
        echo "❌ Not all containers are running"
        return 1
    }
    
    # Test 2: Check cognitod health
    echo "✓ Testing cognitod health..."
    curl -sf http://localhost:3000/healthz || {
        echo "❌ Cognitod health check failed"
        return 1
    }
    
    # Test 3: Check LLM server
    echo "✓ Testing AI model server..."
    curl -sf http://localhost:8090/health || {
        echo "❌ LLM server health check failed"  
        return 1
    }
    
    # Test 4: Check dashboard
    echo "✓ Testing web dashboard..."
    curl -sf http://localhost:8080 | grep -q "Linnix Dashboard" || {
        echo "❌ Web dashboard not responding correctly"
        return 1
    }
    
    # Test 5: Check API endpoints
    echo "✓ Testing API endpoints..."
    curl -sf http://localhost:3000/processes > /dev/null || {
        echo "❌ Processes API not working"
        return 1
    }
    
    # Test 6: Check metrics
    echo "✓ Testing metrics endpoint..."
    curl -sf http://localhost:3000/metrics > /dev/null || {
        echo "❌ Metrics endpoint not working" 
        return 1
    }
    
    echo "🎉 All tests passed! Linnix is working correctly."
    echo
    echo "Access your setup:"
    echo "  • Dashboard: http://localhost:8080"
    echo "  • API: http://localhost:3000" 
    echo "  • Model: http://localhost:8090"
    
    return 0
}

# Run the test
test_quickstart