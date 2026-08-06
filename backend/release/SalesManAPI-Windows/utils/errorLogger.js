const fs = require('fs');
const path = require('path');
const runtime = require('../runtime');

function getLogFilePath() {
  return path.join(runtime.getAppRoot(), 'error.log');
}
const COMPANY_HEADER =
  'Maleesha Sanjana - Jazz Business Solution (Pvt.) Ltd.';
const DAY_SEPARATOR = '='.repeat(80);

let lastLoggedDateKey = null;
let consoleHookInstalled = false;

function getDateKey(date = new Date()) {
  return date.toLocaleDateString('en-CA', { timeZone: 'Asia/Colombo' });
}

function formatDisplayDate(dateKey) {
  const date = new Date(`${dateKey}T12:00:00`);
  return date.toLocaleDateString('en-GB', {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    timeZone: 'Asia/Colombo',
  });
}

function formatTimestamp(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
    timeZone: 'Asia/Colombo',
  }).formatToParts(date);

  const lookup = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${lookup.year}-${lookup.month}-${lookup.day} ${lookup.hour}:${lookup.minute}:${lookup.second}`;
}

function fileHasTodayHeader(todayKey) {
  try {
    const logFile = getLogFilePath();
    if (!fs.existsSync(logFile)) {
      return false;
    }
    const content = fs.readFileSync(logFile, 'utf8');
    return content.includes(`DATE: ${todayKey}`);
  } catch {
    return false;
  }
}

function writeDayHeader(dateKey) {
  const block = [
    '',
    DAY_SEPARATOR,
    `DATE: ${dateKey} (${formatDisplayDate(dateKey)})`,
    COMPANY_HEADER,
    DAY_SEPARATOR,
    '',
  ].join('\n');

  fs.appendFileSync(getLogFilePath(), block, 'utf8');
}

function ensureDayHeader() {
  const todayKey = getDateKey();
  if (lastLoggedDateKey === todayKey) {
    return;
  }

  if (!fileHasTodayHeader(todayKey)) {
    writeDayHeader(todayKey);
  }

  lastLoggedDateKey = todayKey;
}

function formatError(error) {
  if (!error) {
    return '';
  }

  if (error instanceof Error) {
    return [error.message, error.stack].filter(Boolean).join('\n');
  }

  if (typeof error === 'object') {
    try {
      return JSON.stringify(error, null, 2);
    } catch {
      return String(error);
    }
  }

  return String(error);
}

function logError(message, error = null, meta = null) {
  try {
    ensureDayHeader();

    let entry = `[${formatTimestamp()}] ${message}`;
    const errorText = formatError(error);
    if (errorText) {
      entry += `\n${errorText}`;
    }
    if (meta) {
      try {
        entry += `\nMeta: ${JSON.stringify(meta)}`;
      } catch {
        // Ignore meta serialization issues.
      }
    }
    entry += '\n\n';

    fs.appendFileSync(getLogFilePath(), entry, 'utf8');
  } catch (logErr) {
    process.stderr.write(`Failed to write error.log: ${logErr.message}\n`);
  }
}

function installConsoleErrorCapture() {
  if (consoleHookInstalled) {
    return;
  }
  consoleHookInstalled = true;

  const originalError = console.error.bind(console);
  console.error = (...args) => {
    originalError(...args);

    const message = args
      .map((arg) => {
        if (arg instanceof Error) {
          return arg.stack || arg.message;
        }
        if (typeof arg === 'object') {
          try {
            return JSON.stringify(arg);
          } catch {
            return String(arg);
          }
        }
        return String(arg);
      })
      .join(' ');

    logError(message);
  };
}

function installProcessHandlers() {
  process.on('uncaughtException', (err) => {
    logError('Uncaught Exception', err);
  });

  process.on('unhandledRejection', (reason) => {
    logError(
      'Unhandled Promise Rejection',
      reason instanceof Error ? reason : new Error(String(reason)),
    );
  });
}

function initialize() {
  installConsoleErrorCapture();
  installProcessHandlers();
  ensureDayHeader();
  console.log(`📝 Error log file: ${getLogFilePath()}`);
}

module.exports = {
  initialize,
  logError,
  getLogFilePath,
  COMPANY_HEADER,
};
