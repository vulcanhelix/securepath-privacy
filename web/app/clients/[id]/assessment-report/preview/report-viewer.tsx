'use client';

import { useRef, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { Card } from '@/components/ui/Card';

export default function ReportViewer({ src, title }: { src: string; title: string }) {
  const frame = useRef<HTMLIFrameElement>(null);
  const [ready, setReady] = useState(false);

  function downloadPdf() {
    const preview = frame.current?.contentWindow;
    if (!preview) return;
    preview.focus();
    preview.print();
  }

  return (
    <Card
      title="Report preview"
      action={
        <Button size="sm" icon="download" disabled={!ready} onClick={downloadPdf}>
          Download PDF
        </Button>
      }
      pad={0}
    >
      <div style={{ padding: '10px 28px', color: 'var(--muted)', fontSize: 'var(--fs-xs)', borderBottom: '1px solid var(--border)' }}>
        Choose “Save as PDF” in the print dialog. The exported document uses the A4 print layout.
      </div>
      <iframe
        ref={frame}
        src={src}
        title={title}
        onLoad={() => setReady(true)}
        style={{
          display: 'block',
          width: '100%',
          height: 'calc(100vh - 260px)',
          minHeight: 720,
          border: 0,
          background: '#f5f5f5',
        }}
      />
    </Card>
  );
}
