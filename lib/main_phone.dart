import 'package:flutter/material.dart';

import 'phone/phone_app.dart';
import 'phone/phone_bridge.dart';

void main() => runApp(PhoneApp(bridge: ChannelPhoneBridge()));
