namespace Pathleap.UI.Platform;

/// <summary>
/// 主搜索窗几何：宽度取光标所在显示器工作区宽度的 1/3，顶边固定在工作区高度 1/4 处，水平居中。
/// 宽度直接按物理像素算（不做「DIP 取整再乘回」），各缩放档下 widthPx / workWidthPx 都落在 1/3 的 ±1px 内；
/// 高度仍由 DIP 换算成物理像素，调用方用 SetWindowPos 以物理像素落位。
/// </summary>
internal static class MainWindowLayout
{
    /// <summary>宽度占工作区宽度的比例。</summary>
    public const double WidthFraction = 1.0 / 3.0;

    /// <summary>顶边相对工作区高度的位置。</summary>
    public const double TopFraction = 0.25;

    public readonly record struct Frame(int X, int Y, int Width, int Height);

    /// <summary>
    /// 按工作区物理边界与目标缩放计算窗口矩形（物理像素）。
    /// </summary>
    /// <param name="workLeft">工作区左边（物理像素）。</param>
    /// <param name="workTop">工作区上边（物理像素）。</param>
    /// <param name="workRight">工作区右边（物理像素）。</param>
    /// <param name="workBottom">工作区下边（物理像素）。</param>
    /// <param name="scale">该显示器有效缩放（DPI / 96）。</param>
    /// <param name="heightDip">窗口高度（DIP），本次不改。</param>
    public static Frame Compute(int workLeft, int workTop, int workRight, int workBottom, double scale, double heightDip)
    {
        var lpWorkWidth = workRight - workLeft;
        var lpWorkHeight = workBottom - workTop;

        // 取整策略（有意混用，改动前先读这段）：
        // 宽度直接对物理像素取整：widthPx = Round(workWidthPx / 3)。不走「DIP 取整再乘回」——
        // 那条路在 125%/150%/175% 下会把 1 DIP 的舍入放大成 1.25–1.75px，200% 下可差到 2px，
        // 比值就不再稳定落在 1/3 的 ±1px 内。高度仍按 DIP 换算（Round(heightDip × scale)）。
        // 宽高与 Y 用 Math.Round（默认 MidpointRounding.ToEven，银行家舍入），例如工作区高 1750 → 437.5 → 438；
        // X 用整数除法（非负值即向下取整），保持左右留白完全对称：如屏宽 2880、窗宽 960 时 x=960。
        // 若把 X 也改成 Math.Round 或把 Y 改成向下取整，.5 边界会各差 1px，历史几何表就不可比了。
        var lpWidth = (int)Math.Round(lpWorkWidth * WidthFraction);
        var lpHeight = (int)Math.Round(heightDip * scale);
        var lpX = workLeft + (lpWorkWidth - lpWidth) / 2;
        var lpY = workTop + (int)Math.Round(lpWorkHeight * TopFraction);
        return new Frame(lpX, lpY, lpWidth, lpHeight);
    }
}
