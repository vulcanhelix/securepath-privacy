#!/usr/bin/env python3
"""Two-phase helper for record.mjs:
1. waits for record/find-ticket -> finds the demo issue by title, writes
   record/ticket-url.txt
2. waits for record/post-comment -> posts the 'fix working' comment on it.
"""
import json, os, sys, time, urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
KEY = open(DIR + '/demo-key.txt').read().strip()
VIDEO = ('https://uploads.linear.app/ec6e4873-c0b5-4c16-ad94-9f5673ae4af1/'
         '0a9ef325-fae7-42aa-8885-d8e4faef0356/516e57bf-f1e9-42cb-8752-9613a9ed5912')
TITLE = 'The footer shows the product name twice'

def gql(q, v):
    req = urllib.request.Request('https://api.linear.app/graphql',
        data=json.dumps({'query': q, 'variables': v}).encode(),
        headers={'Content-Type': 'application/json', 'Authorization': KEY})
    return json.loads(urllib.request.urlopen(req).read())

def wait_flag(name, secs):
    for _ in range(secs * 2):
        if os.path.exists(DIR + '/' + name):
            return True
        time.sleep(0.5)
    return False

wait_flag('find-ticket', 120)
r = gql('{ issues(first:20, orderBy:createdAt) { nodes { id title url } } }', {})
node = [n for n in r['data']['issues']['nodes'] if n['title'] == TITLE][0]
open(DIR + '/ticket-url.txt', 'w').write(node['url'])
print('ticket:', node['url'])
iid = node['id']

wait_flag('post-comment', 120)
body = ("Here's the fix working: " + VIDEO +
        "\n\nDoes this look right? Reply here to approve and I'll merge it, "
        "or tell me what still looks off.")
r = gql('mutation($i:CommentCreateInput!){commentCreate(input:$i){success}}',
        {'i': {'issueId': iid, 'body': body}})
print('comment posted:', r)
