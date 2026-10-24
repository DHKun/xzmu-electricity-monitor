import { Prefs, Sample } from './Prefs';

export enum PowerLevel {
  UNKNOWN = 0,
  OK = 1,
  WARN = 2,
  LOW = 3
}

/** 由存储推算出的展示状态, App 首页与桌面卡片共用 */
export class PowerView {
  configured: boolean = false;
  qty: number = -1;
  room: string = '';
  level: PowerLevel = PowerLevel.UNKNOWN;
  /** 相对上次充值后最高读数的百分比 0-100 */
  percent: number = 0;
  /** 日均用电(度), <0 表示样本不足 */
  dailyUse: number = -1;
  /** 预计可用天数, <0 表示无法估算 */
  daysLeft: number = -1;
  lastAt: number = 0;
  sessionDead: boolean = false;
  threshold: number = 20;
}

export class PowerStatus {
  static load(): PowerView {
    const v: PowerView = new PowerView();
    v.configured = Prefs.getConfigured();
    v.room = Prefs.getRoomLabel();
    v.threshold = Prefs.getThreshold();
    v.sessionDead = Prefs.isSessionDead();
    v.lastAt = Prefs.getLastAt();
    v.qty = Prefs.getLastQty();
    if (v.qty < 0) {
      return v;
    }
    v.level = PowerStatus.levelOf(v.qty, v.threshold);
    const peak: number = Math.max(Prefs.getPeakQty(), v.qty, 1);
    v.percent = Math.round(Math.min(100, v.qty / peak * 100));
    v.dailyUse = PowerStatus.estimateDaily(Prefs.getSamples());
    if (v.dailyUse > 0.05) {
      v.daysLeft = Math.floor(v.qty / v.dailyUse);
    }
    return v;
  }

  static levelOf(qty: number, threshold: number): PowerLevel {
    if (qty < 0) {
      return PowerLevel.UNKNOWN;
    }
    if (qty < threshold) {
      return PowerLevel.LOW;
    }
    if (qty < threshold * 2) {
      return PowerLevel.WARN;
    }
    return PowerLevel.OK;
  }

  static levelText(level: PowerLevel): string {
    switch (level) {
      case PowerLevel.OK:
        return '电量充足';
      case PowerLevel.WARN:
        return '电量偏低';
      case PowerLevel.LOW:
        return '电量不足';
      default:
        return '暂无数据';
    }
  }

  /** 只用最近一次充值之后的样本, 跨度不足 6 小时不估算 */
  static estimateDaily(samples: Sample[]): number {
    if (samples.length < 2) {
      return -1;
    }
    let start: number = 0;
    for (let i = 1; i < samples.length; i++) {
      if (samples[i].qty > samples[i - 1].qty + 0.5) {
        start = i;
      }
    }
    const first: Sample = samples[start];
    const last: Sample = samples[samples.length - 1];
    const hours: number = (last.at - first.at) / 3600000;
    const used: number = first.qty - last.qty;
    if (hours < 6 || used <= 0) {
      return -1;
    }
    return used / hours * 24;
  }

  static fmtQty(qty: number): string {
    if (qty < 0) {
      return '--';
    }
    return Number.isInteger(qty) ? String(qty) : qty.toFixed(1);
  }

  /** "刚刚 / 12 分钟前 / 今天 08:30 / 10月24日 21:00" */
  static fmtTime(at: number): string {
    if (at <= 0) {
      return '尚未查询';
    }
    const diff: number = Date.now() - at;
    if (diff < 60000) {
      return '刚刚更新';
    }
    if (diff < 3600000) {
      return `${Math.floor(diff / 60000)} 分钟前更新`;
    }
    const d: Date = new Date(at);
    const now: Date = new Date();
    const hm: string = `${PowerStatus.pad(d.getHours())}:${PowerStatus.pad(d.getMinutes())}`;
    if (d.toDateString() === now.toDateString()) {
      return `今天 ${hm} 更新`;
    }
    return `${d.getMonth() + 1}月${d.getDate()}日 ${hm} 更新`;
  }

  /** 卡片上空间小, 只显示时分 */
  static fmtShortTime(at: number): string {
    if (at <= 0) {
      return '';
    }
    const d: Date = new Date(at);
    return `${PowerStatus.pad(d.getHours())}:${PowerStatus.pad(d.getMinutes())}`;
  }

  private static pad(n: number): string {
    return n < 10 ? `0${n}` : String(n);
  }
}
