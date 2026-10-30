-- База данных интернет-магазина.
-- PostgreSQL 11+ (проверено на PostgreSQL 18).
--
-- Запуск:
--   psql -v ON_ERROR_STOP=1 -U shop -d shop -f sql/online_shop.sql
--
-- Повторный запуск удаляет и создаёт объекты схемы заново.
--
-- К обязательной схеме добавлены два поля, без которых не выполняются
-- дополнительные пункты:
--   order_details.price  — цена товара в момент заказа;
--   products.rating      — средний рейтинг, его поддерживает триггер отзывов.

BEGIN;

DROP VIEW IF EXISTS v_user_order_stats;
DROP VIEW IF EXISTS v_orders_with_user_and_product;

DROP TABLE IF EXISTS reviews CASCADE;
DROP TABLE IF EXISTS order_details CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS categories CASCADE;

DROP FUNCTION IF EXISTS get_orders_by_email(varchar);
DROP FUNCTION IF EXISTS get_products_with_high_rating(integer);
DROP FUNCTION IF EXISTS user_orders_total(integer, timestamp, timestamp);
DROP FUNCTION IF EXISTS product_avg_rating(integer);
DROP FUNCTION IF EXISTS refresh_product_rating(integer);
DROP FUNCTION IF EXISTS trg_reviews_refresh_product_rating();
DROP FUNCTION IF EXISTS trg_order_details_sync_price();
DROP FUNCTION IF EXISTS trg_order_details_set_price();

DROP PROCEDURE IF EXISTS add_product(varchar, numeric, integer, integer);
DROP PROCEDURE IF EXISTS update_product(integer, varchar, numeric, integer);
DROP PROCEDURE IF EXISTS delete_product(integer);
DROP PROCEDURE IF EXISTS add_user(varchar, varchar, integer);
DROP PROCEDURE IF EXISTS update_user(integer, varchar, varchar);
DROP PROCEDURE IF EXISTS delete_user(integer);
DROP PROCEDURE IF EXISTS add_order(integer, timestamp, integer);
DROP PROCEDURE IF EXISTS update_order(integer, integer, timestamp);
DROP PROCEDURE IF EXISTS delete_order(integer);
DROP PROCEDURE IF EXISTS add_review(integer, integer, integer, text, integer);
DROP PROCEDURE IF EXISTS update_review(integer, integer, integer, integer, text);
DROP PROCEDURE IF EXISTS delete_review(integer);

-- ---------------------------------------------------------------------------
-- Таблицы и связи
-- ---------------------------------------------------------------------------

CREATE TABLE categories (
    id   SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE
);

CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    price       DECIMAL(10, 2) NOT NULL CHECK (price >= 0),
    category_id INTEGER NOT NULL REFERENCES categories (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    -- Средний рейтинг по отзывам. NULL, пока отзывов нет.
    rating      NUMERIC(3, 2) CHECK (rating IS NULL OR rating BETWEEN 1 AND 5)
);

CREATE TABLE users (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE
        CONSTRAINT users_email_normalized CHECK (email = lower(btrim(email)))
        CONSTRAINT users_email_format CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

CREATE TABLE orders (
    id         SERIAL PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    order_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE order_details (
    id         SERIAL PRIMARY KEY,
    order_id   INTEGER NOT NULL REFERENCES orders (id) ON UPDATE CASCADE ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    quantity   INTEGER NOT NULL CHECK (quantity > 0),
    -- Цена на момент добавления позиции. Нужна, чтобы сумма заказа
    -- не менялась вместе с каталогом.
    price      DECIMAL(10, 2) NOT NULL CHECK (price >= 0),
    UNIQUE (order_id, product_id)
);

CREATE TABLE reviews (
    id         SERIAL PRIMARY KEY,
    product_id INTEGER NOT NULL REFERENCES products (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    user_id    INTEGER NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    rating     INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment    TEXT,
    UNIQUE (product_id, user_id)
);

COMMENT ON TABLE categories IS 'Категории товаров';
COMMENT ON TABLE products IS 'Товары';
COMMENT ON TABLE users IS 'Пользователи';
COMMENT ON TABLE orders IS 'Заказы';
COMMENT ON TABLE order_details IS 'Позиции заказов';
COMMENT ON TABLE reviews IS 'Отзывы на товары';
COMMENT ON COLUMN order_details.price IS 'Цена товара в момент заказа';
COMMENT ON COLUMN products.rating IS 'Средний рейтинг по отзывам, обновляется триггером';

-- ---------------------------------------------------------------------------
-- Индексы для выборок и соединений
-- Внешние ключи в PostgreSQL сами по себе индекс не создают.
-- ---------------------------------------------------------------------------

-- Заказы пользователя и сумма заказов за период.
CREATE INDEX idx_orders_user_id_order_date ON orders (user_id, order_date);

-- Товары выбранной категории.
CREATE INDEX idx_products_category_id ON products (category_id);

-- Поиск позиций по товару.
-- Поиск по order_id обслуживает уникальный индекс (order_id, product_id).
CREATE INDEX idx_order_details_product_id ON order_details (product_id);

-- Отзывы товара и отзывы пользователя.
CREATE INDEX idx_reviews_user_id ON reviews (user_id);

-- Выборка товаров, у которых есть отзыв с рейтингом выше 3.
CREATE INDEX idx_reviews_product_high_rating ON reviews (product_id) WHERE rating > 3;

-- ---------------------------------------------------------------------------
-- Триггеры
-- ---------------------------------------------------------------------------

-- При добавлении позиции и при смене товара фиксирует цену из каталога.
-- Каталожная цена из заказа не меняется: скидка в старом заказе
-- не должна стать ценой для следующих покупателей.
CREATE FUNCTION trg_order_details_set_price()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.product_id IS DISTINCT FROM OLD.product_id THEN
        SELECT price
          INTO NEW.price
          FROM products
         WHERE id = NEW.product_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Товар с id % не найден', NEW.product_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_order_details_set_price
BEFORE INSERT OR UPDATE OF product_id ON order_details
FOR EACH ROW
EXECUTE PROCEDURE trg_order_details_set_price();

-- Пересчитывает products.rating по всем отзывам товара.
-- Сначала блокирует строку товара, и только следующим оператором читает отзывы.
-- Иначе вторая транзакция дождётся блокировки и запишет среднее со старого снимка.
CREATE FUNCTION refresh_product_rating(p_product_id INTEGER)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_avg NUMERIC(3, 2);
BEGIN
    PERFORM 1
      FROM products
     WHERE id = p_product_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Товар % не найден', p_product_id;
    END IF;

    SELECT ROUND(AVG(rating)::numeric, 2)
      INTO v_avg
      FROM reviews
     WHERE product_id = p_product_id;

    UPDATE products
       SET rating = v_avg
     WHERE id = p_product_id;
END;
$$;

CREATE FUNCTION trg_reviews_refresh_product_rating()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    -- При переносе отзыва оба товара блокируются в порядке id,
    -- чтобы две такие операции не ждали друг друга.
    IF TG_OP = 'UPDATE' AND OLD.product_id IS DISTINCT FROM NEW.product_id THEN
        IF OLD.product_id < NEW.product_id THEN
            PERFORM refresh_product_rating(OLD.product_id);
            PERFORM refresh_product_rating(NEW.product_id);
        ELSE
            PERFORM refresh_product_rating(NEW.product_id);
            PERFORM refresh_product_rating(OLD.product_id);
        END IF;
    ELSE
        PERFORM refresh_product_rating(
            CASE WHEN TG_OP = 'DELETE' THEN OLD.product_id ELSE NEW.product_id END
        );
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reviews_refresh_product_rating
AFTER INSERT OR UPDATE OR DELETE ON reviews
FOR EACH ROW
EXECUTE PROCEDURE trg_reviews_refresh_product_rating();

-- ---------------------------------------------------------------------------
-- Хранимые процедуры: товары, пользователи, заказы, отзывы
-- ---------------------------------------------------------------------------

CREATE PROCEDURE add_product(
    p_name VARCHAR(255),
    p_price DECIMAL(10, 2),
    p_category_id INTEGER,
    INOUT p_id INTEGER
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Название товара не может быть пустым';
    END IF;
    IF p_price IS NULL OR p_price < 0 THEN
        RAISE EXCEPTION 'Цена товара должна быть неотрицательной';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM categories WHERE id = p_category_id) THEN
        RAISE EXCEPTION 'Категория % не найдена', p_category_id;
    END IF;

    INSERT INTO products (name, price, category_id)
    VALUES (btrim(p_name), p_price, p_category_id)
    RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE update_product(
    p_id INTEGER,
    p_name VARCHAR(255),
    p_price DECIMAL(10, 2),
    p_category_id INTEGER
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Название товара не может быть пустым';
    END IF;
    IF p_price IS NULL OR p_price < 0 THEN
        RAISE EXCEPTION 'Цена товара должна быть неотрицательной';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM categories WHERE id = p_category_id) THEN
        RAISE EXCEPTION 'Категория % не найдена', p_category_id;
    END IF;

    UPDATE products
       SET name = btrim(p_name),
           price = p_price,
           category_id = p_category_id
     WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Товар % не найден', p_id;
    END IF;
END;
$$;

CREATE PROCEDURE delete_product(p_id INTEGER)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    DELETE FROM products WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Товар % не найден', p_id;
    END IF;
EXCEPTION
    WHEN foreign_key_violation OR restrict_violation THEN
        RAISE EXCEPTION 'Нельзя удалить товар %: он есть в заказах или отзывах', p_id;
END;
$$;

CREATE PROCEDURE add_user(
    p_name VARCHAR(255),
    p_email VARCHAR(255),
    INOUT p_id INTEGER
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Имя пользователя не может быть пустым';
    END IF;
    IF p_email IS NULL OR p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'Некорректный email: %', p_email;
    END IF;

    INSERT INTO users (name, email)
    VALUES (btrim(p_name), lower(btrim(p_email)))
    RETURNING id INTO p_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Пользователь с email % уже существует', lower(btrim(p_email));
END;
$$;

CREATE PROCEDURE update_user(
    p_id INTEGER,
    p_name VARCHAR(255),
    p_email VARCHAR(255)
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'Имя пользователя не может быть пустым';
    END IF;
    IF p_email IS NULL OR p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'Некорректный email: %', p_email;
    END IF;

    UPDATE users
       SET name = btrim(p_name),
           email = lower(btrim(p_email))
     WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Пользователь % не найден', p_id;
    END IF;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Пользователь с email % уже существует', lower(btrim(p_email));
END;
$$;

CREATE PROCEDURE delete_user(p_id INTEGER)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    DELETE FROM users WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Пользователь % не найден', p_id;
    END IF;
EXCEPTION
    WHEN foreign_key_violation OR restrict_violation THEN
        RAISE EXCEPTION 'Нельзя удалить пользователя %: у него есть заказы или отзывы', p_id;
END;
$$;

CREATE PROCEDURE add_order(
    p_user_id INTEGER,
    p_order_date TIMESTAMP,
    INOUT p_id INTEGER
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'Пользователь % не найден', p_user_id;
    END IF;

    INSERT INTO orders (user_id, order_date)
    VALUES (p_user_id, COALESCE(p_order_date, CURRENT_TIMESTAMP))
    RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE update_order(
    p_id INTEGER,
    p_user_id INTEGER,
    p_order_date TIMESTAMP
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'Дата заказа обязательна';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'Пользователь % не найден', p_user_id;
    END IF;

    UPDATE orders
       SET user_id = p_user_id,
           order_date = p_order_date
     WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заказ % не найден', p_id;
    END IF;
END;
$$;

CREATE PROCEDURE delete_order(p_id INTEGER)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    DELETE FROM orders WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заказ % не найден', p_id;
    END IF;
END;
$$;

CREATE PROCEDURE add_review(
    p_product_id INTEGER,
    p_user_id INTEGER,
    p_rating INTEGER,
    p_comment TEXT,
    INOUT p_id INTEGER
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
        RAISE EXCEPTION 'Оценка должна быть от 1 до 5';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = p_product_id) THEN
        RAISE EXCEPTION 'Товар % не найден', p_product_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'Пользователь % не найден', p_user_id;
    END IF;

    INSERT INTO reviews (product_id, user_id, rating, comment)
    VALUES (p_product_id, p_user_id, p_rating, NULLIF(btrim(p_comment), ''))
    RETURNING id INTO p_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Пользователь % уже оставил отзыв на товар %', p_user_id, p_product_id;
END;
$$;

CREATE PROCEDURE update_review(
    p_id INTEGER,
    p_product_id INTEGER,
    p_user_id INTEGER,
    p_rating INTEGER,
    p_comment TEXT
)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
        RAISE EXCEPTION 'Оценка должна быть от 1 до 5';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = p_product_id) THEN
        RAISE EXCEPTION 'Товар % не найден', p_product_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'Пользователь % не найден', p_user_id;
    END IF;

    UPDATE reviews
       SET product_id = p_product_id,
           user_id = p_user_id,
           rating = p_rating,
           comment = NULLIF(btrim(p_comment), '')
     WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Отзыв % не найден', p_id;
    END IF;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Пользователь % уже оставил отзыв на товар %', p_user_id, p_product_id;
END;
$$;

CREATE PROCEDURE delete_review(p_id INTEGER)
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    DELETE FROM reviews WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Отзыв % не найден', p_id;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Представления
-- ---------------------------------------------------------------------------

-- Одна строка — позиция заказа: кто заказал и какой товар.
CREATE VIEW v_orders_with_user_and_product AS
SELECT o.id          AS order_id,
       o.order_date,
       u.id          AS user_id,
       u.name        AS user_name,
       p.id          AS product_id,
       p.name        AS product_name,
       od.quantity,
       od.price,
       od.price * od.quantity AS line_amount
  FROM orders o
  JOIN users u ON u.id = o.user_id
  JOIN order_details od ON od.order_id = o.id
  JOIN products p ON p.id = od.product_id;

-- Количество заказов и общая сумма по каждому пользователю.
CREATE VIEW v_user_order_stats AS
SELECT u.id   AS user_id,
       u.name AS user_name,
       u.email,
       COUNT(DISTINCT o.id) AS orders_count,
       COALESCE(SUM(od.price * od.quantity), 0)::DECIMAL(12, 2) AS total_amount
  FROM users u
  LEFT JOIN orders o ON o.user_id = u.id
  LEFT JOIN order_details od ON od.order_id = o.id
 GROUP BY u.id;

-- ---------------------------------------------------------------------------
-- Запросы задания и функции дополнительных пунктов
-- ---------------------------------------------------------------------------

-- 5. Все заказы пользователя по его email.
--
-- SELECT o.id, o.order_date, u.name, u.email
--   FROM orders o
--   JOIN users u ON u.id = o.user_id
--  WHERE u.email = 'anna@shop.test'
--  ORDER BY o.order_date, o.id;
CREATE FUNCTION get_orders_by_email(p_email VARCHAR)
RETURNS TABLE (
    order_id     INTEGER,
    order_date   TIMESTAMP,
    user_name    VARCHAR,
    email        VARCHAR,
    items_count  BIGINT,
    total_amount DECIMAL(12, 2)
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT o.id,
           o.order_date,
           u.name,
           u.email,
           COUNT(od.id) AS items_count,
           COALESCE(SUM(od.price * od.quantity), 0)::DECIMAL(12, 2) AS total_amount
      FROM orders o
      JOIN users u ON u.id = o.user_id
      LEFT JOIN order_details od ON od.order_id = o.id
     WHERE u.email = lower(btrim(p_email))
     GROUP BY o.id, u.name, u.email
     ORDER BY o.order_date, o.id;
$$;

-- 6. Товары категории, у которых есть отзыв с рейтингом выше 3.
--
-- SELECT p.id, p.name, p.price, p.category_id
--   FROM products p
--  WHERE p.category_id = 1
--    AND EXISTS (
--        SELECT 1
--          FROM reviews r
--         WHERE r.product_id = p.id
--           AND r.rating > 3
--    )
--  ORDER BY p.name;
CREATE FUNCTION get_products_with_high_rating(p_category_id INTEGER)
RETURNS TABLE (
    product_id    INTEGER,
    product_name  VARCHAR,
    price         DECIMAL(10, 2),
    category_id   INTEGER,
    category_name VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
     SELECT p.id,
           p.name,
           p.price,
           p.category_id,
           c.name
      FROM products p
      JOIN categories c ON c.id = p.category_id
     WHERE p.category_id = p_category_id
       AND EXISTS (
           SELECT 1
             FROM reviews r
            WHERE r.product_id = p.id
              AND r.rating > 3
       )
     ORDER BY p.name;
$$;

-- Общая стоимость заказов пользователя за период [p_from, p_to).
-- Конец не входит в период, чтобы соседние отрезки не пересекались.
CREATE FUNCTION user_orders_total(
    p_user_id INTEGER,
    p_from TIMESTAMP,
    p_to TIMESTAMP
)
RETURNS DECIMAL(12, 2)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_total DECIMAL(12, 2);
BEGIN
    IF p_user_id IS NULL OR p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'Нужно указать пользователя и обе границы периода';
    END IF;
    IF p_from >= p_to THEN
        RAISE EXCEPTION 'Начало периода должно быть раньше его конца';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'Пользователь % не найден', p_user_id;
    END IF;

    SELECT COALESCE(SUM(od.price * od.quantity), 0)
      INTO v_total
      FROM orders o
      JOIN order_details od ON od.order_id = o.id
     WHERE o.user_id = p_user_id
       AND o.order_date >= p_from
       AND o.order_date < p_to;

    RETURN v_total;
END;
$$;

-- Средний рейтинг товара по всем его отзывам. NULL, если отзывов нет.
CREATE FUNCTION product_avg_rating(p_product_id INTEGER)
RETURNS NUMERIC(3, 2)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_avg NUMERIC(3, 2);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM products WHERE id = p_product_id) THEN
        RAISE EXCEPTION 'Товар % не найден', p_product_id;
    END IF;

    SELECT ROUND(AVG(rating)::numeric, 2)
      INTO v_avg
      FROM reviews
     WHERE product_id = p_product_id;

    RETURN v_avg;
END;
$$;

COMMIT;
