#!/usr/bin/env python3
"""Import a private, inert Codex rendering fixture into a Wonder QA database.

Only writes beneath this checkout's target/. Never starts or resumes a model.
Embedded images need Pillow; remote images and local source paths are not fetched.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import uuid
from datetime import datetime, timezone


def stamp(value):
    return int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() * 1000)


def messages(records):
    """Preserve response items and call pairing; ignore reasoning contents."""
    turns, current, calls = [], None, {}
    for record in records:
        if record.get('type') != 'response_item':
            continue
        p = record.get('payload', {})
        kind, at = p.get('type'), record.get('timestamp')
        if not at:
            continue
        if kind == 'message':
            role = p.get('role')
            if role not in ('user', 'assistant') or p.get('channel') in ('analysis', 'summary'):
                continue
            parts = p.get('content', [])
            text = '\n'.join(x.get('text', '') for x in parts if x.get('type') in ('input_text', 'output_text', 'text'))
            if role == 'user':
                if text.startswith(('# AGENTS.md', '<environment_context>', '<permissions instructions>', '<user_instructions>', '<turn_aborted>')):
                    continue
                if '## My request:\n' in text:
                    text = text.split('## My request:\n', 1)[1]
                current = {'id': str(uuid.uuid4()), 'at': at, 'text': text, 'parts': parts, 'items': []}
                turns.append(current)
            elif current is not None:
                phase = p.get('phase') or p.get('channel')
                current['items'].append({'id': str(uuid.uuid4()), 'type': 'agentMessage', 'text': text,
                                         'phase': 'commentary' if phase == 'commentary' else 'final_answer', 'createdAt': at, 'status': 'completed', 'parts': parts})
        elif current is not None and kind in ('function_call', 'custom_tool_call'):
            item = {'id': str(uuid.uuid4()), 'type': 'dynamicToolCall', 'tool': p.get('name', 'Tool'),
                    'arguments': p.get('arguments', p.get('input', '')), 'status': 'interrupted', 'createdAt': at}
            current['items'].append(item)
            calls[p.get('call_id')] = item
        elif kind in ('function_call_output', 'custom_tool_call_output'):
            if (item := calls.get(p.get('call_id'))) is not None:
                item['contentItems'] = p.get('output', [])
                item['status'] = 'completed'
                item['updatedAt'] = at
        elif kind == 'reasoning' and current is not None:
            current['items'].append({'id': str(uuid.uuid4()), 'type': 'reasoning', 'status': 'completed', 'createdAt': at})
    return turns


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--database', type=Path, required=True)
    parser.add_argument('--title', required=True)
    parser.add_argument('--turns', type=int, default=4)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1] / 'target'
    database = args.database.resolve(strict=True)
    if not database.is_relative_to(root.resolve()) or not 1 <= args.turns <= 20:
        parser.error('Use an existing database beneath this checkout target/ and 1–20 turns.')
    os.umask(0o077)
    selected = messages(json.loads(line) for line in args.source.open())[-args.turns:]
    if not selected:
        parser.error('No eligible conversation turns.')
    bot = str(uuid.uuid4()); conversation = 'bot:' + bot
    workspace = root / 'codex-replays' / bot
    workspace.mkdir(parents=True, mode=0o700)
    c = sqlite3.connect(database)
    c.execute('PRAGMA foreign_keys=ON')
    device = c.execute('SELECT id FROM devices WHERE is_local=1 LIMIT 1').fetchone()
    if not device:
        parser.error('QA database needs a local owner.')
    epoch = c.execute('SELECT host_epoch FROM sync_state').fetchone()[0]
    now = datetime.now(timezone.utc).isoformat()
    counts = {'turns': len(selected), 'commentary': 0, 'final': 0, 'toolCalls': 0, 'toolResults': 0, 'reasoningMarkers': 0, 'images': 0, 'unavailableMedia': 0}
    with c:
        c.execute('INSERT INTO bots(id,name,workspace_path,permission_profile,created_at,is_archived) VALUES(?,?,?,?,?,1)', (bot,args.title,str(workspace),'workspace_only',now))
        c.execute('INSERT INTO conversations(id,created_at) VALUES(?,?)', (conversation,now))
        c.execute('INSERT INTO conversation_metadata(id,bot_id,title,is_pinned,created_at,updated_at) VALUES(?,?,?,1,?,?)', (conversation,bot,args.title,now,now))
        c.execute('INSERT INTO bot_workspaces VALUES(?,?,?,?)', (bot,conversation,now,now))
        def media(parts, message=None):
            if not isinstance(parts, list):
                return parts
            result = []
            for part in parts:
                if not isinstance(part, dict):
                    continue
                if part.get('type') not in ('input_image','inputImage','image'):
                    result.append(part); continue
                uri = part.get('image_url', part.get('imageUrl', ''))
                if isinstance(uri, dict): uri = uri.get('url','')
                if not uri and part.get('data') and part.get('mimeType'):
                    uri = 'data:' + part['mimeType'] + ';base64,' + part['data']
                try:
                    header, encoded = uri.split(',',1)
                    if header not in ('data:image/png;base64','data:image/jpeg;base64','data:image/gif;base64','data:image/webp;base64') or len(encoded) > 12_000_000:
                        raise ValueError('Unsupported image')
                    raw = base64.b64decode(encoded, validate=True)
                    if len(raw) > 8 * 1024 * 1024: raise ValueError('Large image')
                    from PIL import Image
                    with Image.open(io.BytesIO(raw)) as image:
                        mime = Image.MIME[image.format]
                        if image.width > 8192 or image.height > 8192 or image.width * image.height > 16_000_000: raise ValueError('Large image')
                        image.verify()
                    if mime != header[5:-7]: raise ValueError('MIME mismatch')
                    ident = str(uuid.uuid4()); relative = '.wonder/attachments/' + ident
                    path = workspace / relative; path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(raw)
                    name = 'Codex image ' + str(counts['images'] + 1)
                    digest = hashlib.sha256(raw).hexdigest()
                    c.execute('INSERT INTO conversation_files(id,conversation_id,kind,name,relative_path,state,created_at,updated_at,mime_type,byte_size,sha256) VALUES(?,?,?,?,?,\'available\',?,?,?,?,?)', (ident,conversation,'attachment',name,relative,now,now,mime,len(raw),digest))
                    if message: c.execute('INSERT INTO message_attachments VALUES(?,?,?)', (message,ident,now))
                    result.append({'type':'wonderArtifact','file':{'id':ident,'name':name,'mimeType':mime,'byteSize':len(raw),'sha256':digest,'state':'available','updatedAt':now}})
                    counts['images'] += 1
                except (ValueError, KeyError, OSError, ImportError):
                    counts['unavailableMedia'] += 1
                    result.append({'type':'text','text':'Image preview unavailable in this replay.'})
            return result
        for turn in selected:
            ident = str(uuid.uuid4()); body = turn['text']; at = turn['at']
            c.execute('INSERT INTO messages(id,device_id,client_message_id,body_sha256,conversation_id,state,codex_thread_id,codex_turn_id,created_at,body) VALUES(?,?,?,?,?,\'completed\',?,?,?,?)', (ident,device[0],ident,hashlib.sha256(body.encode()).hexdigest(),conversation,'private-replay',turn['id'],at,body))
            media(turn['parts'],ident)
            for item in turn['items']:
                if item['type'] == 'agentMessage':
                    counts['commentary' if item['phase']=='commentary' else 'final'] += 1
                    c.execute('INSERT INTO assistant_messages VALUES(?,?,?,?,?,?,?,?,?)', (item['id'],conversation,'private-replay',turn['id'],item['id'],item['text'],'completed',item['createdAt'],item['createdAt']))
                    # Retain text in the durable store; lifecycle event retains its phase.
                    media(item.pop('parts',[]))
                elif item['type'] == 'reasoning': counts['reasoningMarkers'] += 1
                else:
                    counts['toolCalls'] += 1
                    if 'contentItems' in item:
                        counts['toolResults'] += 1; item['contentItems'] = media(item['contentItems'])
                event = {'eventId':item['id'],'hostEpoch':epoch,'sequence':0,'occurredAt':item['createdAt'],'conversationId':conversation,'threadId':'private-replay','turnId':turn['id'],'itemId':item['id'],'event':{'type':'activity','data':{'category':'thread_item_upsert','state':'completed','detail':json.dumps({'turnId':turn['id'],'itemId':item['id'],'item':item})}}}
                c.execute('INSERT INTO history_entries(conversation_id,source,source_id,sort_ms,payload_json) VALUES(?,\'event\',?,?,?)', (conversation,item['id'],stamp(item['createdAt']),json.dumps(event)))
    report = {'title':args.title,'conversationId':conversation,'source':str(args.source.resolve()),'counts':counts,'runtimeAttached':False}
    (workspace/'manifest.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({'manifest':str(workspace/'manifest.json'),'conversationId':conversation,'counts':counts},indent=2))

if __name__ == '__main__': main()
