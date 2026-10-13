(function () {
  var PITCH = {
    rising: 58, opening: 84, extracting: 66, lowering: 52,
    arm_return: 72, closing: 80, retracting: 46
  };

  var context = null;
  var motor = null;
  var grind = null;
  var filter = null;
  var gain = null;
  var current = 0;

  function noiseBuffer(ctx) {
    var frames = Math.floor(ctx.sampleRate * 1.5);
    var buffer = ctx.createBuffer(1, frames, ctx.sampleRate);
    var data = buffer.getChannelData(0);
    var value = 0;
    for (var i = 0; i < frames; i++) {
      value = (value + (Math.random() * 2 - 1) * 0.22) * 0.94;
      data[i] = value;
    }
    return buffer;
  }

  function build() {
    var Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return false;
    try {
      context = new Ctx();
    } catch (error) {
      context = null;
      return false;
    }
    gain = context.createGain();
    gain.gain.value = 0;
    filter = context.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.value = 900;
    filter.Q.value = 0.7;
    motor = context.createOscillator();
    motor.type = 'sawtooth';
    motor.frequency.value = 58;
    grind = context.createBufferSource();
    grind.buffer = noiseBuffer(context);
    grind.loop = true;
    var grindGain = context.createGain();
    grindGain.gain.value = 0.35;
    motor.connect(filter);
    grind.connect(grindGain);
    grindGain.connect(filter);
    filter.connect(gain);
    gain.connect(context.destination);
    motor.start();
    grind.start();
    return true;
  }

  function apply(phase, volume) {
    var level = Math.max(0, Math.min(1, Number(volume) || 0));
    if (!context) {
      if (level <= 0) return;
      if (!build()) return;
    }
    if (level > 0 && context.state === 'suspended' && context.resume) context.resume();
    var now = context.currentTime;
    var pitch = PITCH[phase] || 58;
    motor.frequency.setTargetAtTime(pitch, now, 0.08);
    filter.frequency.setTargetAtTime(600 + pitch * 8, now, 0.12);
    gain.gain.setTargetAtTime(level, now, 0.06);
    current = level;
    if (level <= 0 && context.suspend) {
      window.setTimeout(function () {
        if (current <= 0 && context && context.state === 'running') context.suspend();
      }, 400);
    }
  }

  window.addEventListener('message', function (event) {
    var data = event.data || {};
    if (data.action === 'mechanism') apply(data.phase, data.volume);
  });
})();
