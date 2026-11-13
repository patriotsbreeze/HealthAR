import CoreGraphics
import Testing
@testable import PlumbCapture

struct DepthCellsTests {
    let cells = DepthCells(intrinsics: TestScene.intrinsics, mapWidth: 256, mapHeight: 192)

    @Test func scaleIsCellsPerPixel() {
        #expect(cells.scale.x == 256.0 / 1920.0)
        #expect(cells.scale.y == 192.0 / 1440.0)
    }

    @Test func cornersLandInCornerCells() {
        #expect(cells.cell(u: 0, v: 0) == (0, 0))
        #expect(cells.cell(u: 1919, v: 1439) == (255, 191))
    }

    @Test func eachCellCoversSevenAndAHalfPixels() {
        // Pixel centres 0...6 fall in cell 0 and 7...14 in cell 1, since 7.5 pixels make a cell.
        #expect(cells.cell(u: 6, v: 6).column == 0)
        #expect(cells.cell(u: 7, v: 7).column == 1)
        #expect(cells.cell(u: 14, v: 14).row == 1)
        #expect(cells.cell(u: 15, v: 15).row == 2)
        #expect(cells.cell(u: 960, v: 720) == (128, 96))
    }

    @Test func pixelsOffTheImageGiveCellsOffTheMap() {
        #expect(cells.cell(u: -20, v: -20) == (-3, -3))
        #expect(cells.cell(u: 2000, v: 1500).column == 266)
    }

    @Test func nonsenseCoordinatesDoNotTrap() {
        _ = cells.cell(u: .nan, v: .infinity)
        _ = cells.cell(u: -.infinity, v: 1e300)
    }

    @Test func windowIsCentredOnTheCellUnderThePixel() {
        #expect(cells.window(centredOnU: 960, v: 720, columns: 7, rows: 7)
            == CellWindow(column: 125, row: 93, columns: 7, rows: 7))
        #expect(cells.window(centredOnU: 960, v: 720, columns: 4, rows: 6)
            == CellWindow(column: 126, row: 93, columns: 4, rows: 6))
    }

    @Test func windowCoversItsBoundsWithinTheCaps() {
        // 203 x 348 pixels is 27.1 x 46.4 cells: rounded up, inside the 32 x 48 caps.
        let fits = cells.window(centredOnU: 960, v: 720, covering: CGRect(x: 0, y: 0, width: 203, height: 348),
                                maxColumns: 32, maxRows: 48, minCells: 4)
        #expect(fits.columns == 28 && fits.rows == 47)
        let capped = cells.window(centredOnU: 960, v: 720, covering: CGRect(x: 0, y: 0, width: 406, height: 696),
                                  maxColumns: 32, maxRows: 48, minCells: 4)
        #expect(capped == CellWindow(column: 112, row: 72, columns: 32, rows: 48))
        let tiny = cells.window(centredOnU: 960, v: 720, covering: CGRect(x: 0, y: 0, width: 3, height: 3),
                                maxColumns: 32, maxRows: 48, minCells: 4)
        #expect(tiny.columns == 4 && tiny.rows == 4)
    }
}
