// pam-OSC. It allows to controll GrandMA3 with Midi Devices over Open Stage Controll and allows for Feedback from MA.
// Copyright (C) 2024  xxpasixx

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>. 


// Todo: Refactor: This is only a temp solution
var displayDevice = null;
var colors = ["0;0;0;0", "0;0;0;0", "0;0;0;0", "0;0;0;0", "0;0;0;0", "0;0;0;0", "0;0;0;0", "0;0;0;0"]

const utils = require('./utils.js');
const colorUtils = require('./colorUtils.js');
const routingUtils = require('./routingUtils.js');
const midiUtils = require('./midiUtils.js');

var routing = {};

let encoderFine = false;
let encoderRough = false;
let currentAttribute = "dimmer";

var prefix = "";
var page = "1";

const ipPort = ('' +settings.read("send")).split(":");
const ip = ipPort[0];
const oscPort = ipPort[1];

settings.read("midi").forEach(deviceMidi => {
	const name = deviceMidi.split(":")[0];
	const fileName = name + ".json";

	const value = loadJSON('mappings/' + fileName, (e) => console.error("The Mapping " + fileName + " could not be found. Please make sure it exists, or rename your MIDI Device name to a existing one"));
	value.buttonFeedbackMapper = eval('(' + value.buttonFeedbackMapper + ')');
	routing[name] = value;
	console.log("loaded mapping: ", fileName);
});

midiUtils.sendAttributeLED(routing, currentAttribute);

module.exports = {
	oscInFilter: function (data) {
		var { address, args, host, port } = data

		if (host === 'midi') {
			if (address === '/control') {
				var [channel, ctrl, value] = args.map(arg => arg.value);
				if (routing[port]['control'][ctrl]) {
					send(ip, oscPort, prefix + "/Page" + page + "/Fader" + routing[port]['control'][ctrl], { type: "i", value: value });
				}

				// handle relative Rotary encoders to act as Absolute
				if (routing[port]['rltvControl'][ctrl] && routing[port]['rltvControl'][ctrl].exec) {
					const { exec, currValue, posFrom, posTo, negFrom, negTo } = routing[port]['rltvControl'][ctrl];
					var newValue = currValue + utils.getRelativeValue(value, posFrom, posTo, negFrom, negTo);
					newValue = Math.min(Math.max(newValue, 0), 127) || 0;
					routing[port]['rltvControl'][ctrl].currValue = newValue;
					
					send(ip, oscPort, prefix + "/Page" + page + "/Fader" + exec, { type: "i", value: newValue });
				}

				// handle attribute Encoders
				if (routing[port]['rltvControl'][ctrl] && routing[port]['rltvControl'][ctrl].attribute) {
					const { attribute, posFrom, posTo, negFrom, negTo, amount } = routing[port]['rltvControl'][ctrl];
					
					let change = utils.getRelativeValue(value, posFrom, posTo, negFrom, negTo) * amount;
					change = encoderFine ? change / 10 : change;
					change = encoderRough ? change * 10 : change;
					const plusMinus = change > 0 ? " + " : " - ";
					const attributeToSend = attribute == "current" ? currentAttribute : attribute;
					send(ip, oscPort, prefix + "/cmd", {type :"s", value:  "Attribute " + attributeToSend + " at " + plusMinus + Math.abs(change)});
				}
			}
			if (address === '/pitch') {
				var [channel, value] = args.map(arg => arg.value);
				if (!routing[port]['pitch'][channel]) {
					return;
				}
				const valueMapped = Math.round((value / 16380) * 127);
				send(ip, oscPort, prefix + "/Page" + page + "/Fader" + routing[port]['pitch'][channel], { type: "i", value: valueMapped });

			}
			if (address === '/note') {
				var [channel, ctrl, value] = args.map(arg => arg.value);
				var config = routing[port]['note'][ctrl];

				if (!config) {
					return;
				}

				if (config.minValue && value <= config.minValue) {
					return;
				}

				if (config.exec) {
					send(ip, oscPort, prefix + "/Page" + page + "/Key" + config.exec, { type: "i", value: value });
				}

				if (config.quicKey) {
					send(ip, oscPort, prefix + "/cmd", { type: "s", value: 'Go+ Quickey \"' + config.quicKey + '\"' });
				}

				if (config.cmd) {
					send(ip, oscPort, prefix + "/cmd", { type: "s", value: config.cmd });
				}

				if (config.local) {
					if (config.local == "encoderRough") {
						encoderRough = !encoderRough;
						midiUtils.sendNoteResponse(routing, port, ctrl, encoderRough ? "On" : "Off");
					}
					if (config.local == "encoderFine") {
						encoderFine = !encoderFine;
						midiUtils.sendNoteResponse(routing, port, ctrl, encoderFine ? "On" : "Off");
					}
					
					if (config.local == "attribute" && config.attribute) {
						currentAttribute = config.attribute;
						midiUtils.sendAttributeLED(routing, currentAttribute);
					}
				}
			}
			return;
		}

		if (host === ip) {
			const addressSplit = address.split('/')
			const fader = address.substring(address.length - 3, address.length);

			if (addressSplit[2].includes('Fader')) {
				const mappingsCtrl = routingUtils.getRoutingByControlerId(routing, fader);
				const mappingsPitch = routingUtils.getRoutingByPitchId(routing, fader);
				const mappingsRltvCtrl = routingUtils.getRoutingByRltvControlerId(routing, fader);

				mappingsCtrl.forEach((mapping) => {
					send('midi', mapping.device, '/control', 1, mapping.midiId, args[0].value);
				});

				mappingsPitch.forEach((mapping) => {
					const valueMapped = Math.round((args[0].value / 127) * 16380);
					send('midi', mapping.device, '/pitch', mapping.midiId, valueMapped);
				});

				mappingsRltvCtrl.forEach((mapping) => {
					const value = utils.mapValue(args[0].value, 0, 127, mapping.from, mapping.to);
					routing[mapping.device].rltvControl[mapping.id].currValue = args[0].value;
					send('midi', mapping.device, '/control', 1, mapping.midiId, value);
				});
			}
			if (addressSplit[2].includes('Button')) {
				const mappings = routingUtils.getRoutingNoteByExecId(routing, fader);
				mappings.forEach((mapping) => {
					midiUtils.sendNoteResponse(routing, mapping.device, mapping.midiId, args[0].value);
				});
			}
			if (address.includes('/updatePage/current')) {
				page = "" + args[0].value;
			}
			if (addressSplit[1].includes('masterEnabled')) {
				const mappings = routingUtils.getRoutingNoteByCMD(routing, addressSplit[2]);

				mappings.forEach((mapping) => {
					midiUtils.sendNoteResponse(routing, mapping.device, mapping.midiId, args[0].value ? 'On' : 'Off');
				});
			}

			if (addressSplit[2].includes('Color')) {
				const mappingsDisplay = routingUtils.getRoutingByDisplayId(routing, fader);

				mappingsDisplay.forEach((mapping) => {
					colors[mapping.displayId] = args[0].value;
					displayDevice = mapping.device;
				});

				if (!displayDevice) {
					return;
				}
				var midiCommand = "F0 00 00 66 14 72";
				colors.forEach(colorString => {
					const color = colorUtils.parseColorString(colorString);
					const displayColor = colorUtils.findNearestDisplayColor(color);
					midiCommand = midiCommand + displayColor + " ";
				});
				send('midi', displayDevice, '/sysex', midiCommand + "F7");
			}

			if (addressSplit[2].includes('Name')) {
				const mappingsDisplay = routingUtils.getRoutingByDisplayId(routing, fader);
				const values = args[0].value.split(";");

				mappingsDisplay.forEach((mapping) => {
					const seqMidiNote = utils.numberIntoHex(mapping.displayId * 7);
					const cueMidiNote = utils.numberIntoHex(56 + (mapping.displayId * 7));
					const seq = (values[0] + "       ").substring(0, 7);
					const cue = (values[1] + "       ").substring(0, 7);

					send('midi', mapping.device, '/sysex', "f0 00 00 66 14 12 " + seqMidiNote + " " + utils.stringToAsciiHex(seq) + "f7");
					send('midi', mapping.device, '/sysex', "f0 00 00 66 14 12 " + cueMidiNote + " " + utils.stringToAsciiHex(cue) + "f7");
				});
			}
		}

		return { address, args, host, port }
	},
}