#!/usr/bin/env python3
"""
Fetch the Insight JSON Schema from a running cognitod instance.
This schema is used to validate insight records in the dataset pipeline.
"""
import argparse
import json
import sys
import urllib.request
import urllib.error


def fetch_schema(endpoint: str, output: str) -> None:
    """Fetch schema from cognitod and save to file."""
    schema_url = f"{endpoint}/insights/schema"
    
    print(f"Fetching schema from {schema_url}...", file=sys.stderr)
    
    try:
        with urllib.request.urlopen(schema_url) as response:
            schema = json.loads(response.read().decode())
        
        # Pretty-print to output file
        with open(output, 'w') as f:
            json.dump(schema, f, indent=2)
        
        print(f"✅ Schema saved to {output}", file=sys.stderr)
        print(f"Schema version: {schema.get('version', 'unknown')}", file=sys.stderr)
        
    except urllib.error.URLError as e:
        print(f"❌ Error fetching schema: {e}", file=sys.stderr)
        print(f"Is cognitod running at {endpoint}?", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"❌ Error parsing schema JSON: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--endpoint',
        default='http://localhost:3000',
        help='Cognitod HTTP endpoint (default: http://localhost:3000)'
    )
    parser.add_argument(
        '--output',
        default='datasets/schema/insight.schema.json',
        help='Output file path (default: datasets/schema/insight.schema.json)'
    )
    
    args = parser.parse_args()
    fetch_schema(args.endpoint, args.output)


if __name__ == '__main__':
    main()
