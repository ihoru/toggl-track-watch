import 'package:flutter/material.dart';

import 'wear/wear_app.dart';
import 'wear/watch_bridge.dart';

void main() => runApp(WearApp(bridge: ChannelWatchBridge()));
