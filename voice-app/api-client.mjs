import { VoiceAPI } from '@castreader/voice-api';
import { Client, VoiceError } from './voice.mjs';

const bases = new Set(['https://voice.castreader.com/v1', 'https://voice.castreader.cn/v1']);

/** The official SDK, pinned to one execution region for the life of a batch. */
export class RegionalVoiceAPI extends VoiceAPI {
  constructor({ apiKey = process.env.CASTREADER_API_KEY, baseURL }) {
    if (!bases.has(baseURL)) throw new VoiceError('invalid_route');
    super({ apiKey, baseURL, route: false, maxRetries: 0 });
    this.transport = new Client({ apiKey });
  }
  static async connect() {
    const transport = new Client();
    return new RegionalVoiceAPI({ baseURL: await transport.route() });
  }
  forRegion(baseURL) { return new RegionalVoiceAPI({ apiKey: this.apiKey, baseURL }); }
  async verifyVoiceRegion(voiceId) {
    if (await this.transport.route(voiceId) !== this.baseURL) throw new VoiceError('regional_voice_required');
  }
  async voices() {
    return { data: await this.transport.voices(this.baseURL), has_more: false };
  }
  async capabilities() {
    const response = await fetch('https://voice.castreader.com/integration-manifest.json', {
      redirect: 'error', signal: AbortSignal.timeout(20000),
    });
    if (!response.ok) throw new VoiceError('configuration_unavailable');
    const { capabilities } = await response.json();
    if (!capabilities?.service_enabled || !capabilities.new_work_admission_enabled || !capabilities.queued_jobs) throw new VoiceError('admission_paused');
    const limit = capabilities.max_characters_per_queued_job;
    if (!Number.isSafeInteger(limit) || limit < 1) throw new VoiceError('invalid_catalog');
    return { maxCharacters: Math.min(500, limit) };
  }
  async getJob(id) {
    if (!/^job_[a-f0-9]{32}$/.test(id)) throw new VoiceError('invalid_job');
    const { data, retryAfterMs } = await this.transport.request(this.baseURL, `/jobs/${id}`);
    return { ...data, retryAfterMs };
  }
}
