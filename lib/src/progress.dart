import 'document.dart';

/// Where a read is.
enum ReadStage {
  /// Waiting for the card to touch the phone.
  waitingForCard,

  /// The card is there: selecting its application and unlocking it. A good
  /// moment for a short vibration.
  unlocking,

  /// Reading files. Keep the card still.
  reading,

  /// The card can go: checking signatures on the phone.
  checking,

  done,
}

/// Sent while a read runs, for your own progress screen.
class ReadProgress {
  const ReadProgress(this.stage,
      {this.attempt = 1, this.fraction = 0, this.partial});

  final ReadStage stage;

  /// 1, then 2, 3… after the card moved and the reader waits for it again.
  final int attempt;

  /// Share of the planned bytes read so far, 0 to 1. Sizes are estimates
  /// until each file starts.
  final double fraction;

  /// The values read so far, before any check. Lets you show the name
  /// while the photo still loads.
  final IdDocument? partial;
}
