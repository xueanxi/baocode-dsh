import 'package:baocode/kernel/dsh/dsh_route.dart';

/// The route the DSH tests start their fake dsh on: a value of the test's own,
/// never the machine's file (`dsh_route.dart`). The ref is the one the fake
/// route reads, so that a test can say whether dsh can resolve it.
const testDshRoute = DshRoute(
  provider: 'stepcodev2',
  baseUrl: 'https://i-ai-gw.stepx.com/v1',
  apiKeyEnv: 'STEPCODEV2_API_KEY',
  model: 'deepseek-v4.1-flash',
  contextWindow: 512000,
);
