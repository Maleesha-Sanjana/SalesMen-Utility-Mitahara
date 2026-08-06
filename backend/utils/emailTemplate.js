function getNewDeviceLoginEmailHtml(userName, deviceName, platform, time) {
  return `
  <!DOCTYPE html>
  <html>
  <head>
    <style>
      body { font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f4f4f5; margin: 0; padding: 0; }
      .container { max-width: 600px; margin: 40px auto; background-color: #ffffff; border-radius: 12px; overflow: hidden; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06); }
      .header { background-color: #18181b; padding: 24px; text-align: center; }
      .header h1 { color: #ffffff; margin: 0; font-size: 24px; font-weight: 600; letter-spacing: -0.025em; }
      .content { padding: 32px; color: #3f3f46; line-height: 1.6; }
      .content p { margin-top: 0; font-size: 16px; }
      .details { background-color: #f4f4f5; border-radius: 8px; padding: 16px; margin: 24px 0; }
      .details p { margin: 8px 0; font-size: 14px; }
      .details strong { color: #18181b; }
      .warning { border-left: 4px solid #ef4444; background-color: #fef2f2; padding: 16px; border-radius: 0 8px 8px 0; margin-top: 24px; }
      .warning p { color: #991b1b; font-size: 14px; margin: 0; }
      .footer { background-color: #f4f4f5; padding: 24px; text-align: center; color: #71717a; font-size: 12px; }
    </style>
  </head>
  <body>
    <div class="container">
      <div class="header">
        <h1>New Device Login Alert</h1>
      </div>
      <div class="content">
        <p>Hi <strong>Maleesha Sanjana</strong>,</p>
        <p>User <strong>${userName}</strong> just logged into Sales Man Utility from a new, unrecognized device.</p>
        
        <div class="details">
          <p><strong>Device:</strong> ${deviceName || 'Unknown Device'}</p>
          <p><strong>Platform:</strong> ${platform || 'Unknown Platform'}</p>
          <p><strong>Time:</strong> ${time}</p>
        </div>

        <div class="warning">
          <p><strong>Action Required:</strong> If this login is unexpected, please log in to the Super Admin Dashboard to review or revoke this device's access.</p>
        </div>
      </div>
      <div class="footer">
        &copy; ${new Date().getFullYear()} Sales Man Utility
      </div>
    </div>
  </body>
  </html>
  `;
}

module.exports = { getNewDeviceLoginEmailHtml };
