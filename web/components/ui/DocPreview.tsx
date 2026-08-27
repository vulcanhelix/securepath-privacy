'use client';
import * as React from 'react';
import { Button } from './Button';
import { Icon } from './Icon';

// Preview an uploaded document in a modal — streams inline through /api/documents (RLS-checked).
export function DocPreview({ docId, filename }: { docId: string; filename: string }) {
  const [open, setOpen] = React.useState(false);

  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open]);

  return (
    <>
      <Button size="sm" variant="ghost" onClick={() => setOpen(true)} icon="eye">
        Preview
      </Button>
      {open ? (
        <div className="sp-modal-scrim" onClick={() => setOpen(false)}>
          <div className="sp-modal" onClick={(e) => e.stopPropagation()}>
            <header className="sp-modal-hd">
              <span style={{ fontWeight: 500, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{filename}</span>
              <span style={{ display: 'inline-flex', gap: 8, flex: 'none' }}>
                <a href={`/api/documents/${docId}`}>
                  <Button size="sm" variant="secondary" icon="download">Download</Button>
                </a>
                <Button size="sm" variant="ghost" onClick={() => setOpen(false)} icon="x" aria-label="Close">
                  Close
                </Button>
              </span>
            </header>
            <iframe src={`/api/documents/${docId}?inline=1`} title={filename} className="sp-modal-body" />
          </div>
        </div>
      ) : null}
    </>
  );
}
