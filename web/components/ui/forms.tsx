import * as React from 'react';

// ponytail: one file for the five tiny form primitives — split if any grows real logic

export function Input({ invalid, className, ...rest }: React.InputHTMLAttributes<HTMLInputElement> & { invalid?: boolean }) {
  return <input className={'sp-input' + (invalid ? ' sp-input--invalid' : '') + (className ? ' ' + className : '')} {...rest} />;
}

export function Select({ invalid, className, children, ...rest }: React.SelectHTMLAttributes<HTMLSelectElement> & { invalid?: boolean }) {
  return (
    <select className={'sp-select' + (invalid ? ' sp-select--invalid' : '') + (className ? ' ' + className : '')} {...rest}>
      {children}
    </select>
  );
}

export function Textarea({ style, ...rest }: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className="sp-textarea" style={{ minHeight: 100, resize: 'vertical', ...style }} {...rest} />;
}

export function Field({
  label,
  required,
  hint,
  error,
  children,
}: {
  label: React.ReactNode;
  required?: boolean;
  hint?: React.ReactNode;
  error?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <div className="sp-field">
      <label className="sp-field-label">
        {label}
        {required ? <span className="sp-field-req"> *</span> : null}
      </label>
      {children}
      {error ? <div className="sp-field-hint sp-field-hint--err">{error}</div> : hint ? <div className="sp-field-hint">{hint}</div> : null}
    </div>
  );
}

export function Checkbox({ label, ...rest }: React.InputHTMLAttributes<HTMLInputElement> & { label: React.ReactNode }) {
  return (
    <label className="sp-check">
      <input type="checkbox" {...rest} />
      <span>{label}</span>
    </label>
  );
}
