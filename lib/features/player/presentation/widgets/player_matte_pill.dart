import 'package:flutter/material.dart';
import 'package:skystream/shared/widgets/matte_glass_pill.dart';

/// The matte glass behind a group of the player's bottom-bar controls.
class PlayerMattePill extends StatelessWidget {
  const PlayerMattePill({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MatteGlassPill(
      // The bar fades inside an opacity layer. Replacing its backdrop avoids
      // blending the filtered image twice during that fade.
      blendMode: BlendMode.src,
      child: child,
    );
  }
}
