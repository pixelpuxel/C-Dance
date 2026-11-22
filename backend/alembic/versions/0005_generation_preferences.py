"""Add synchronized generation favorites and ratings.

Revision ID: 0005
Revises: 0004
"""
from alembic import op
import sqlalchemy as sa

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    columns = {column["name"] for column in inspector.get_columns("generations")}
    if "favorite" not in columns:
        op.add_column("generations", sa.Column("favorite", sa.Boolean(), nullable=False, server_default=sa.false()))
    if "rating" not in columns:
        op.add_column("generations", sa.Column("rating", sa.Integer(), nullable=True))

    constraints = {constraint["name"] for constraint in inspector.get_check_constraints("generations")}
    if "ck_generations_rating_range" not in constraints:
        op.create_check_constraint("ck_generations_rating_range", "generations", "rating IS NULL OR (rating >= 1 AND rating <= 5)")


def downgrade() -> None:
    op.drop_constraint("ck_generations_rating_range", "generations", type_="check")
    op.drop_column("generations", "rating")
    op.drop_column("generations", "favorite")
