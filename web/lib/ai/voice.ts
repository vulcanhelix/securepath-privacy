export interface VoiceTransport {
  speak(text: string): void;
  listen(onText: (text: string) => void): () => void;
}

interface SpeechRecognitionResultEvent {
  results: ArrayLike<ArrayLike<{ transcript: string }>>;
}

interface SpeechRecognitionInstance {
  onresult: ((event: SpeechRecognitionResultEvent) => void) | null;
  start(): void;
  stop(): void;
}

interface SpeechRecognitionConstructor {
  new (): SpeechRecognitionInstance;
}

interface SpeechRecognitionWindow extends Window {
  SpeechRecognition?: SpeechRecognitionConstructor;
  webkitSpeechRecognition?: SpeechRecognitionConstructor;
}

export const browserVoice: VoiceTransport = {
  speak(text) {
    if (typeof window !== 'undefined' && 'speechSynthesis' in window) window.speechSynthesis.speak(new SpeechSynthesisUtterance(text));
  },
  listen(onText) {
    if (typeof window === 'undefined') return () => {};
    const Recognition = (window as SpeechRecognitionWindow).SpeechRecognition || (window as SpeechRecognitionWindow).webkitSpeechRecognition;
    if (!Recognition) return () => {};
    const recognition = new Recognition();
    recognition.onresult = event => onText(event.results[0][0].transcript);
    recognition.start();
    return () => recognition.stop();
  },
};
