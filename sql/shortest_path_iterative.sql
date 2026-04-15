

CREATE OR REPLACE FUNCTION shortest_path_iterative(
        poly geometry,
        obstacles geometry,
        p_start geometry,
        p_end geometry,
        grid_size float,
        buffer_size float,
        iterations int
    ) RETURNS geometry AS $$
DECLARE current_geom geometry := poly;
current_path geometry;
i int;
BEGIN FOR i IN 1..iterations LOOP 
-- =========================
-- 1. GRID
-- =========================
DROP TABLE IF EXISTS grid_base;
CREATE TEMP TABLE grid_base AS
SELECT g.geom
FROM (
        SELECT (ST_SquareGrid(grid_size, current_geom)).geom
    ) g
WHERE ST_Intersects(g.geom, current_geom);
-- =========================
-- 2. DELETE BORDER CASES
-- =========================
DELETE FROM grid_base
WHERE EXISTS (
        SELECT 1
        FROM (
                SELECT obstacles AS geom
            ) o
        WHERE ST_Intersects(grid_base.geom, o.geom)
    );
-- =========================
-- 3. POINTS
-- =========================
DROP TABLE IF EXISTS points_full;
CREATE TEMP TABLE points_full AS
SELECT row_number() OVER () AS id,
    points,
    geom
FROM (
        SELECT 'grid' AS points,
            ST_PointOnSurface(geom) AS geom
        FROM grid_base
        UNION ALL
        SELECT 'init' AS points,
            p_start
        UNION ALL
        SELECT 'end' AS points,
            p_end
    ) sub;
CREATE INDEX ON points_full USING GIST (geom);
-- =========================
-- 4. EDGES (KNN)
-- =========================
DROP TABLE IF EXISTS edges;
CREATE TEMP TABLE edges AS
SELECT row_number() OVER () AS id,
    a.id AS source,
    b.id AS target,
    ST_Distance(a.geom, b.geom) AS cost
FROM points_full a
    JOIN LATERAL (
        SELECT b.*
        FROM points_full b
        WHERE b.id != a.id
        ORDER BY a.geom <->b.geom
        LIMIT 6
    ) b ON true;
-- =========================
-- 5. DIJKSTRA
-- =========================
WITH start_end AS (
    SELECT MAX(
            CASE
                WHEN points = 'init' THEN id
            END
        ) AS start_id,
        MAX(
            CASE
                WHEN points = 'end' THEN id
            END
        ) AS end_id
    FROM points_full
),
dijkstra AS (
    SELECT *
    FROM start_end,
        pgr_dijkstra(
            'SELECT id, source, target, cost FROM edges',
            start_id,
            end_id,
            directed := false
        )
)
SELECT ST_MakeLine(
        p.geom
        ORDER BY d.seq
    ) INTO current_path
FROM dijkstra d
    JOIN points_full p ON d.node = p.id;
-- =========================
-- 6. REFINEMENT
-- =========================
current_geom := ST_Intersection(
    poly,
    ST_Buffer(current_path, buffer_size)
);
grid_size := grid_size / 2;
buffer_size := buffer_size / 2;
END LOOP;
RETURN current_path;
END;
$$ LANGUAGE plpgsql;








