export interface VoiceTransport {
  speak(text: string): void;
  listen(onText: (text: string) => void): () => void;
}

export const browserVoice: VoiceTransport = {
  speak(text) {
    if (typeof window !== 'undefined' && 'speechSynthesis' in window) window.speechSynthesis.speak(new SpeechSynthesisUtterance(text));
  },
  listen(onText) {
    const Recognition = (window as unknown as { SpeechRecognition?: new () => { onresult: (event: { results: { [key: number]: { [key: number]: { transcript: string } } } }) => void; start: () => void; stop: () => void } }).SpeechRecognition;
    if (!Recognition) return () => {};
    const recognition = new Recognition();
    recognition.onresult = event => onText(event.results[0][0].transcript);
    recognition.start();
    return () => recognition.stop();
  },
};
